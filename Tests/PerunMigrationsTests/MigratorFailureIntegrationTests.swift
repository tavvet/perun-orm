import Foundation
import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
@testable import PerunMigrations
import PerunPGSQL
import PerunSQLite
import Testing

@Test
func sqliteMigratorFailureHardeningIntegration() async throws {
    try await runMigratorFailureHardeningIntegration(
        database: SQLiteDatabase(
            configuration: .memory(),
            maxConnections: 1
        )
    )
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresMigratorFailureHardeningIntegration() async throws {
    try await runMigratorFailureHardeningIntegration(
        database: PostgresDatabase(
            configuration: failureIntegrationPostgresConfiguration(),
            maxConnections: 1
        )
    )
}

private func runMigratorFailureHardeningIntegration(
    database: any ExclusiveTransactionDatabase
) async throws {
    let tables = FailureIntegrationTables()

    do {
        try await failureDropTables(tables.all, from: database)
        for probeTable in tables.probes {
            try await failureCreateProbeTable(probeTable, in: database)
        }

        try await assertSwallowedExecutorErrorRollsBackAndRetries(
            database: database,
            trackingTable: tables.swallowedTracking,
            probeTable: tables.swallowedProbe
        )
        try await assertCancellationRollsBackAndRetries(
            database: database,
            trackingTable: tables.cancellationTracking,
            probeTable: tables.cancellationProbe
        )
        try await assertEscapedOperationRollsBackAndRetries(
            database: database,
            trackingTable: tables.escapedTracking,
            probeTable: tables.escapedProbe
        )
        try await assertDelayedContextCannotReachDatabase(
            database: database,
            trackingTable: tables.delayedTracking,
            probeTable: tables.delayedProbe
        )
        try await assertMetadataMutationRollsBackAndRetries(
            database: database,
            trackingTable: tables.metadataTracking,
            probeTable: tables.metadataProbe
        )
        try await assertUnknownCommitRecoversFromHistory(
            database: database,
            trackingTable: tables.unknownCommitTracking,
            probeTable: tables.unknownCommitProbe
        )

        try await failureDropTables(tables.all, from: database)
    } catch {
        await failureBestEffortDropTables(tables.all, from: database)
        await database.shutdown()
        throw error
    }

    await database.shutdown()
}

private func assertSwallowedExecutorErrorRollsBackAndRetries(
    database: any ExclusiveTransactionDatabase,
    trackingTable: String,
    probeTable: String
) async throws {
    let reference = failureReference("001_swallowed_error")
    let caughtErrors = FailureCountProbe()
    let migrator = try Migrator(
        database: database,
        migrations: [
            Migration(id: reference.id) { context in
                try await failureInsertProbe(
                    context: context,
                    table: probeTable,
                    position: 1,
                    marker: "before-error"
                )
                do {
                    try await failureInsertProbe(
                        context: context,
                        table: probeTable,
                        position: 1,
                        marker: "duplicate"
                    )
                } catch {
                    await caughtErrors.increment()
                }
            },
        ],
        trackingTableName: trackingTable
    )

    #expect(
        try await migrator.status()
            == MigrationStatus(applied: [], pending: [reference])
    )
    await expectFailureExecutionError(.contextRollbackOnly) {
        try await migrator.migrate()
    }

    #expect(await caughtErrors.value() == 1)
    try await expectFailureRollback(
        database: database,
        trackingTable: trackingTable,
        probeTable: probeTable
    )
    try await assertFailureRetry(
        database: database,
        reference: reference,
        trackingTable: trackingTable,
        probeTable: probeTable,
        marker: "retry-after-error"
    )
}

private func assertCancellationRollsBackAndRetries(
    database: any ExclusiveTransactionDatabase,
    trackingTable: String,
    probeTable: String
) async throws {
    let reference = failureReference("001_cancelled")
    let gate = FailureSuspensionGate()
    let statements = FailureSQLProbe()
    let caughtCancellations = FailureCountProbe()
    let recordingDatabase = FailureRecordingDatabase(
        base: database,
        statements: statements
    )
    let migrator = try Migrator(
        database: recordingDatabase,
        migrations: [
            Migration(id: reference.id) { context in
                try await failureInsertProbe(
                    context: context,
                    table: probeTable,
                    position: 1,
                    marker: "cancelled"
                )
                await gate.suspend()
                do {
                    try Task.checkCancellation()
                } catch is CancellationError {
                    await caughtCancellations.increment()
                }
            },
        ],
        trackingTableName: trackingTable
    )

    _ = try await migrator.status()
    let operation = Task {
        try await migrator.migrate()
    }
    let suspensionWatchdog = Task {
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            return
        }
        await gate.abort()
    }
    await gate.waitUntilSuspended()
    suspensionWatchdog.cancel()
    await suspensionWatchdog.value
    guard await gate.didSuspend() else {
        operation.cancel()
        await gate.release()
        _ = try? await operation.value
        Issue.record("migration body did not reach the cancellation gate")
        return
    }
    operation.cancel()
    await gate.release()

    do {
        _ = try await operation.value
        Issue.record("cancelled migrate unexpectedly committed")
    } catch is CancellationError {
        // Expected: cancellation after the body write rolls back the complete batch.
    } catch {
        Issue.record("cancelled migrate returned an unexpected error: \(error)")
    }

    #expect(await caughtCancellations.value() == 1)
    #expect(await statements.insertCount(for: trackingTable) == 0)
    try await expectFailureRollback(
        database: database,
        trackingTable: trackingTable,
        probeTable: probeTable
    )
    try await assertFailureRetry(
        database: database,
        reference: reference,
        trackingTable: trackingTable,
        probeTable: probeTable,
        marker: "retry-after-cancellation"
    )
}

private func assertEscapedOperationRollsBackAndRetries(
    database: any ExclusiveTransactionDatabase,
    trackingTable: String,
    probeTable: String
) async throws {
    let reference = failureReference("001_escaped_operation")
    let gate = FailureStatementGate()
    let capturedContext = FailureContextCapture()
    let gatedDatabase = FailureGatedDatabase(
        base: database,
        matchingSQL: probeTable,
        gate: gate
    )
    let migrator = try Migrator(
        database: gatedDatabase,
        migrations: [
            Migration(id: reference.id) { context in
                await capturedContext.store(context)
                _ = Task {
                    try? await failureInsertProbe(
                        context: context,
                        table: probeTable,
                        position: 1,
                        marker: "escaped"
                    )
                }
                await gate.waitUntilBlocked()
            },
        ],
        trackingTableName: trackingTable
    )

    _ = try await migrator.status()
    let operation = Task {
        try await migrator.migrate()
    }
    let statementWatchdog = Task {
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            return
        }
        await gate.abort()
    }
    await gate.waitUntilBlocked()
    statementWatchdog.cancel()
    await statementWatchdog.value
    guard await gate.didBlock() else {
        operation.cancel()
        await gate.release()
        _ = try? await operation.value
        Issue.record("escaped operation did not reach the transaction gate")
        return
    }
    guard let context = await capturedContext.value() else {
        operation.cancel()
        await gate.release()
        _ = try? await operation.value
        Issue.record("migration body did not expose its context before escaping")
        return
    }
    await waitUntilFailureContextStartsClosing(context)
    await gate.release()

    await expectFailureExecutionError(.contextOperationEscaped) {
        try await operation.value
    }
    try await expectFailureRollback(
        database: database,
        trackingTable: trackingTable,
        probeTable: probeTable
    )
    try await assertFailureRetry(
        database: database,
        reference: reference,
        trackingTable: trackingTable,
        probeTable: probeTable,
        marker: "retry-after-escape"
    )
}

private func assertDelayedContextCannotReachDatabase(
    database: any ExclusiveTransactionDatabase,
    trackingTable: String,
    probeTable: String
) async throws {
    let reference = failureReference("001_delayed_context")
    let capturedContext = FailureContextCapture()
    let migrator = try Migrator(
        database: database,
        migrations: [
            Migration(id: reference.id) { context in
                await capturedContext.store(context)
            },
        ],
        trackingTableName: trackingTable
    )

    #expect(try await migrator.migrate() == MigrationReport(applied: [reference]))
    let context = try #require(await capturedContext.value())
    let statement = try failureProbeInsertStatement(
        renderer: context.renderer,
        table: probeTable,
        position: 1,
        marker: "delayed"
    )
    await expectFailureExecutionError(.contextClosed) {
        try await context.execute(statement.sql, statement.parameters)
    }

    #expect(try await failureProbeRows(in: probeTable, database: database).isEmpty)
    #expect(
        try await failureTrackingRowCount(
            in: trackingTable,
            database: database
        ) == 1
    )
}

private func assertMetadataMutationRollsBackAndRetries(
    database: any ExclusiveTransactionDatabase,
    trackingTable: String,
    probeTable: String
) async throws {
    let reference = failureReference("001_metadata_mutation")
    let migrator = try Migrator(
        database: database,
        migrations: [
            Migration(id: reference.id) { context in
                try await failureInsertProbe(
                    context: context,
                    table: probeTable,
                    position: 1,
                    marker: "metadata-mutated"
                )
                try await failureInsertUnexpectedMetadata(
                    context: context,
                    trackingTable: trackingTable
                )
            },
        ],
        trackingTableName: trackingTable
    )

    _ = try await migrator.status()
    do {
        _ = try await migrator.migrate()
        Issue.record("migrate accepted a persistent metadata mutation")
    } catch let error as MigrationHistoryError {
        #expect(error == .reservedMetadataChanged)
    } catch {
        Issue.record("metadata mutation returned an unexpected error: \(error)")
    }

    try await expectFailureRollback(
        database: database,
        trackingTable: trackingTable,
        probeTable: probeTable
    )
    try await assertFailureRetry(
        database: database,
        reference: reference,
        trackingTable: trackingTable,
        probeTable: probeTable,
        marker: "retry-after-metadata-mutation"
    )
}

private func assertUnknownCommitRecoversFromHistory(
    database: any ExclusiveTransactionDatabase,
    trackingTable: String,
    probeTable: String
) async throws {
    let reference = failureReference("001_unknown_commit")
    let preparation = try Migrator(
        database: database,
        migrations: [Migration(id: reference.id) { _ in }],
        trackingTableName: trackingTable
    )
    _ = try await preparation.status()

    let failure = FailureOnce()
    let uncertainDatabase = FailureUnknownCommitDatabase(
        base: database,
        failure: failure
    )
    let bodyCalls = FailureCountProbe()
    let uncertainMigrator = try Migrator(
        database: uncertainDatabase,
        migrations: [
            Migration(id: reference.id) { context in
                await bodyCalls.increment()
                try await failureInsertProbe(
                    context: context,
                    table: probeTable,
                    position: 1,
                    marker: "committed"
                )
            },
        ],
        trackingTableName: trackingTable
    )

    do {
        _ = try await uncertainMigrator.migrate()
        Issue.record("simulated lost commit acknowledgement unexpectedly returned success")
    } catch let error as FailureIntegrationError {
        #expect(error == .commitAcknowledgementLost)
    } catch {
        Issue.record("unknown commit simulation returned an unexpected error: \(error)")
    }

    #expect(await bodyCalls.value() == 1)
    #expect(
        try await failureProbeRows(in: probeTable, database: database) == [
            FailureProbeRow(position: 1, marker: "committed"),
        ]
    )
    #expect(
        try await failureTrackingRowCount(
            in: trackingTable,
            database: database
        ) == 1
    )

    let recoveryBodyCalls = FailureCountProbe()
    let recoveryMigrator = try Migrator(
        database: uncertainDatabase,
        migrations: [
            Migration(id: reference.id) { _ in
                await recoveryBodyCalls.increment()
            },
        ],
        trackingTableName: trackingTable
    )

    #expect(try await recoveryMigrator.migrate() == MigrationReport(applied: []))
    #expect(await recoveryBodyCalls.value() == 0)
    #expect(
        try await recoveryMigrator.status()
            == MigrationStatus(applied: [reference], pending: [])
    )
}

private func assertFailureRetry(
    database: any ExclusiveTransactionDatabase,
    reference: MigrationReference,
    trackingTable: String,
    probeTable: String,
    marker: String
) async throws {
    let migrator = try Migrator(
        database: database,
        migrations: [
            Migration(id: reference.id, revision: reference.revision) { context in
                try await failureInsertProbe(
                    context: context,
                    table: probeTable,
                    position: 1,
                    marker: marker
                )
            },
        ],
        trackingTableName: trackingTable
    )

    #expect(try await migrator.migrate() == MigrationReport(applied: [reference]))
    #expect(
        try await failureProbeRows(in: probeTable, database: database) == [
            FailureProbeRow(position: 1, marker: marker),
        ]
    )
    #expect(
        try await failureTrackingRowCount(
            in: trackingTable,
            database: database
        ) == 1
    )
}

private func expectFailureRollback(
    database: any Database,
    trackingTable: String,
    probeTable: String
) async throws {
    #expect(try await failureProbeRows(in: probeTable, database: database).isEmpty)
    #expect(
        try await failureTrackingRowCount(
            in: trackingTable,
            database: database
        ) == 0
    )
}

private func expectFailureExecutionError<T: Sendable>(
    _ expected: MigrationExecutionError,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("operation unexpectedly succeeded instead of throwing \(expected)")
    } catch let error as MigrationExecutionError {
        #expect(error == expected)
    } catch {
        Issue.record("operation returned an unexpected error: \(error)")
    }
}

private func waitUntilFailureContextStartsClosing(_ context: MigrationContext) async {
    for _ in 0 ..< 10_000 {
        do {
            _ = try await context.execute("SELECT 1", [])
            Issue.record("late context probe unexpectedly reached the database")
            return
        } catch let error as MigrationExecutionError {
            switch error {
            case .contextClosed:
                return
            case .contextBusy, .contextRollbackOnly:
                await Task.yield()
            default:
                Issue.record("late context probe returned \(error)")
                return
            }
        } catch {
            Issue.record("late context probe returned an unexpected error: \(error)")
            return
        }
    }
    Issue.record("migration runner did not start closing the escaped context")
}

private func failureInsertProbe(
    context: MigrationContext,
    table: String,
    position: Int64,
    marker: String
) async throws {
    let statement = try failureProbeInsertStatement(
        renderer: context.renderer,
        table: table,
        position: position,
        marker: marker
    )
    _ = try await context.execute(statement.sql, statement.parameters)
}

private func failureProbeInsertStatement(
    renderer: SQLRenderer,
    table: String,
    position: Int64,
    marker: String
) throws -> RenderedSQL {
    try renderer.render(
        SQLInsert(
            table: table,
            values: [
                SQLColumnValue(column: "position", value: .int(position)),
                SQLColumnValue(column: "marker", value: .text(marker)),
            ]
        )
    )
}

private func failureInsertUnexpectedMetadata(
    context: MigrationContext,
    trackingTable: String
) async throws {
    let statement = try context.renderer.render(
        SQLInsert(
            table: trackingTable,
            values: [
                SQLColumnValue(column: "position", value: .int(99)),
                SQLColumnValue(column: "id", value: .text("999_intruder")),
                SQLColumnValue(column: "revision", value: .int(1)),
                SQLColumnValue(
                    column: "applied_at",
                    value: .date(
                        SQLTimestamp(microsecondsSinceUnixEpoch: 1_700_000_000_000_000)
                    )
                ),
            ]
        )
    )
    _ = try await context.execute(statement.sql, statement.parameters)
}

private func failureReference(_ id: String) -> MigrationReference {
    MigrationReference(position: 1, id: id, revision: 1)
}

private func failureCreateProbeTable(
    _ tableName: String,
    in database: any Database
) async throws {
    let statement = try SQLRenderer(dialect: database.dialect).render(
        SQLCreateTable(
            table: tableName,
            columns: [
                SQLColumnDefinition(
                    name: "position",
                    type: .int64,
                    role: .primaryKey(generated: false)
                ),
                SQLColumnDefinition(name: "marker", type: .text),
            ]
        )
    )
    _ = try await database.execute(statement.sql, statement.parameters)
}

private func failureProbeRows(
    in tableName: String,
    database: any Database
) async throws -> [FailureProbeRow] {
    let statement = try SQLRenderer(dialect: database.dialect).render(
        SQLSelect(
            table: tableName,
            columns: ["position", "marker"],
            orderings: [SQLOrdering(column: "position")]
        )
    )
    let result = try await database.execute(statement.sql, statement.parameters)
    return try result.rows.map { row in
        FailureProbeRow(
            position: try row.decode("position", as: Int64.self),
            marker: try row.decode("marker", as: String.self)
        )
    }
}

private func failureTrackingRowCount(
    in tableName: String,
    database: any Database
) async throws -> Int64 {
    let statement = try SQLRenderer(dialect: database.dialect).render(
        SQLCount(table: tableName)
    )
    let result = try await database.execute(statement.sql, statement.parameters)
    let row = try #require(result.rows.first)
    return try row.decode(SQLCount.resultColumn, as: Int64.self)
}

private func failureDropTables(
    _ tableNames: [String],
    from database: any Database
) async throws {
    for tableName in tableNames {
        let quotedTable = database.dialect.quoteIdentifier(tableName)
        _ = try await database.execute("DROP TABLE IF EXISTS \(quotedTable)", [])
    }
}

private func failureBestEffortDropTables(
    _ tableNames: [String],
    from database: any Database
) async {
    for tableName in tableNames {
        let quotedTable = database.dialect.quoteIdentifier(tableName)
        _ = try? await database.execute("DROP TABLE IF EXISTS \(quotedTable)", [])
    }
}

private struct FailureIntegrationTables {
    let swallowedTracking: String
    let swallowedProbe: String
    let cancellationTracking: String
    let cancellationProbe: String
    let escapedTracking: String
    let escapedProbe: String
    let delayedTracking: String
    let delayedProbe: String
    let metadataTracking: String
    let metadataProbe: String
    let unknownCommitTracking: String
    let unknownCommitProbe: String

    init() {
        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        swallowedTracking = "perun_f_sw_tracking_\(suffix)"
        swallowedProbe = "perun_f_sw_probe_\(suffix)"
        cancellationTracking = "perun_f_ca_tracking_\(suffix)"
        cancellationProbe = "perun_f_ca_probe_\(suffix)"
        escapedTracking = "perun_f_es_tracking_\(suffix)"
        escapedProbe = "perun_f_es_probe_\(suffix)"
        delayedTracking = "perun_f_de_tracking_\(suffix)"
        delayedProbe = "perun_f_de_probe_\(suffix)"
        metadataTracking = "perun_f_md_tracking_\(suffix)"
        metadataProbe = "perun_f_md_probe_\(suffix)"
        unknownCommitTracking = "perun_f_uc_tracking_\(suffix)"
        unknownCommitProbe = "perun_f_uc_probe_\(suffix)"

        precondition(
            all.allSatisfy { $0.utf8.count <= 63 },
            "failure integration table names must remain portable"
        )
    }

    var probes: [String] {
        [
            swallowedProbe,
            cancellationProbe,
            escapedProbe,
            delayedProbe,
            metadataProbe,
            unknownCommitProbe,
        ]
    }

    var all: [String] {
        probes + [
            swallowedTracking,
            cancellationTracking,
            escapedTracking,
            delayedTracking,
            metadataTracking,
            unknownCommitTracking,
        ]
    }
}

private struct FailureProbeRow: Sendable, Equatable {
    let position: Int64
    let marker: String
}

private actor FailureCountProbe {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor FailureSuspensionGate {
    private var isSuspended = false
    private var isReleased = false
    private var suspendedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        isSuspended = true
        let currentSuspendedWaiters = suspendedWaiters
        suspendedWaiters.removeAll(keepingCapacity: false)
        for waiter in currentSuspendedWaiters {
            waiter.resume()
        }

        if !isReleased {
            await withCheckedContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        }
    }

    func waitUntilSuspended() async {
        if isSuspended {
            return
        }
        await withCheckedContinuation { continuation in
            if isSuspended {
                continuation.resume()
            } else {
                suspendedWaiters.append(continuation)
            }
        }
    }

    func didSuspend() -> Bool {
        isSuspended
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let currentReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in currentReleaseWaiters {
            waiter.resume()
        }
    }

    func abort() {
        release()
        let currentSuspendedWaiters = suspendedWaiters
        suspendedWaiters.removeAll(keepingCapacity: false)
        for waiter in currentSuspendedWaiters {
            waiter.resume()
        }
    }
}

private actor FailureStatementGate {
    private var isBlocked = false
    private var isReleased = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        isBlocked = true
        let currentBlockedWaiters = blockedWaiters
        blockedWaiters.removeAll(keepingCapacity: false)
        for waiter in currentBlockedWaiters {
            waiter.resume()
        }

        if !isReleased {
            await withCheckedContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        }
    }

    func waitUntilBlocked() async {
        if isBlocked {
            return
        }
        await withCheckedContinuation { continuation in
            if isBlocked {
                continuation.resume()
            } else {
                blockedWaiters.append(continuation)
            }
        }
    }

    func didBlock() -> Bool {
        isBlocked
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let currentReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in currentReleaseWaiters {
            waiter.resume()
        }
    }

    func abort() {
        release()
        let currentBlockedWaiters = blockedWaiters
        blockedWaiters.removeAll(keepingCapacity: false)
        for waiter in currentBlockedWaiters {
            waiter.resume()
        }
    }
}

private actor FailureContextCapture {
    private var context: MigrationContext?

    func store(_ context: MigrationContext) {
        self.context = context
    }

    func value() -> MigrationContext? {
        context
    }
}

private actor FailureSQLProbe {
    private var statements: [String] = []

    func record(_ sql: String) {
        statements.append(sql)
    }

    func insertCount(for tableName: String) -> Int {
        statements.count {
            $0.hasPrefix("INSERT INTO") && $0.contains(tableName)
        }
    }
}

private struct FailureRecordingDatabase: ExclusiveTransactionDatabase {
    let base: any ExclusiveTransactionDatabase
    let statements: FailureSQLProbe

    var dialect: any SQLDialect {
        base.dialect
    }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        await statements.record(sql)
        return try await base.execute(sql, parameters, intent: intent)
    }

    func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        try await base.withTransaction { transaction in
            try await body(
                FailureRecordingTransaction(
                    base: transaction,
                    statements: statements
                )
            )
        }
    }

    func withExclusiveTransaction<T: Sendable>(
        lockKey: DatabaseLockKey,
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        try await base.withExclusiveTransaction(lockKey: lockKey) { transaction in
            try await body(
                FailureRecordingTransaction(
                    base: transaction,
                    statements: statements
                )
            )
        }
    }

    func shutdown() async {
        await base.shutdown()
    }
}

private struct FailureRecordingTransaction: Transaction {
    let base: any Transaction
    let statements: FailureSQLProbe

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        await statements.record(sql)
        return try await base.execute(sql, parameters, intent: intent)
    }
}

private struct FailureGatedDatabase: ExclusiveTransactionDatabase {
    let base: any ExclusiveTransactionDatabase
    let matchingSQL: String
    let gate: FailureStatementGate

    var dialect: any SQLDialect {
        base.dialect
    }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await base.execute(sql, parameters, intent: intent)
    }

    func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        try await base.withTransaction(body)
    }

    func withExclusiveTransaction<T: Sendable>(
        lockKey: DatabaseLockKey,
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        try await base.withExclusiveTransaction(lockKey: lockKey) { transaction in
            try await body(
                FailureGatedTransaction(
                    base: transaction,
                    matchingSQL: matchingSQL,
                    gate: gate
                )
            )
        }
    }

    func shutdown() async {
        await base.shutdown()
    }
}

private struct FailureGatedTransaction: Transaction {
    let base: any Transaction
    let matchingSQL: String
    let gate: FailureStatementGate

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        if sql.contains(matchingSQL) {
            await gate.block()
        }
        return try await base.execute(sql, parameters, intent: intent)
    }
}

private struct FailureUnknownCommitDatabase: ExclusiveTransactionDatabase {
    let base: any ExclusiveTransactionDatabase
    let failure: FailureOnce

    var dialect: any SQLDialect {
        base.dialect
    }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await base.execute(sql, parameters, intent: intent)
    }

    func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        try await base.withTransaction(body)
    }

    func withExclusiveTransaction<T: Sendable>(
        lockKey: DatabaseLockKey,
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        let result = try await base.withExclusiveTransaction(lockKey: lockKey, body)
        if await failure.consume() {
            throw FailureIntegrationError.commitAcknowledgementLost
        }
        return result
    }

    func shutdown() async {
        await base.shutdown()
    }
}

private actor FailureOnce {
    private var shouldFail = true

    func consume() -> Bool {
        guard shouldFail else { return false }
        shouldFail = false
        return true
    }
}

private enum FailureIntegrationError: Error, Sendable, Equatable {
    case commitAcknowledgementLost
}

private func failureIntegrationPostgresConfiguration() -> ConnectionConfiguration {
    let environment = ProcessInfo.processInfo.environment
    let tlsMode: TLSMode
    switch environment["PGSSLMODE"] {
    case "disable":
        tlsMode = .disable
    case "prefer", "allow-plaintext-fallback":
        tlsMode = .allowPlaintextFallback
    case "require", "encrypt-without-verification":
        tlsMode = .encryptWithoutVerification
    default:
        tlsMode = .verifyFull
    }

    return ConnectionConfiguration(
        host: environment["PGHOST"] ?? "localhost",
        port: UInt16(environment["PGPORT"] ?? "") ?? 5_432,
        user: environment["PGUSER"] ?? "perun",
        database: environment["PGDATABASE"] ?? "perun",
        password: environment["PGPASSWORD"],
        tlsMode: tlsMode
    )
}
