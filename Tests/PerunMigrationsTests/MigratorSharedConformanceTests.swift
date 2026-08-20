import Foundation
import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
@testable import PerunMigrations
import PerunPGSQL
import PerunSQLite
import Testing

@Test
func sqliteMigratorSharedConformance() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "perun-migrator-conformance-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )

    var primaryConfiguration = SQLiteConfiguration(
        path: directory.appendingPathComponent("database.sqlite").path,
        journalMode: .wal
    )
    primaryConfiguration.busyTimeout = .seconds(10)
    var contenderConfiguration = primaryConfiguration
    contenderConfiguration.busyTimeout = .milliseconds(100)
    let reopenConfiguration = primaryConfiguration

    let primary = SQLiteDatabase(
        client: SQLiteClient(configuration: primaryConfiguration, maxConnections: 1)
    )
    let contender = SQLiteDatabase(
        client: SQLiteClient(configuration: contenderConfiguration, maxConnections: 1)
    )

    do {
        try await runMigratorSharedConformance(
            primary: primary,
            contender: contender,
            backend: .sqlite,
            reopenDatabase: {
                SQLiteDatabase(
                    client: SQLiteClient(
                        configuration: reopenConfiguration,
                        maxConnections: 1
                    )
                )
            }
        )
        await primary.shutdown()
        await contender.shutdown()
        try FileManager.default.removeItem(at: directory)
    } catch {
        await primary.shutdown()
        await contender.shutdown()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresMigratorSharedConformance() async throws {
    let primaryConfiguration = sharedConformancePostgresConfiguration()
    let primary = PostgresDatabase(
        configuration: primaryConfiguration,
        maxConnections: 1
    )
    let contender = PostgresDatabase(
        configuration: sharedConformancePostgresConfiguration(lockTimeout: "250ms"),
        maxConnections: 1
    )

    do {
        try await runMigratorSharedConformance(
            primary: primary,
            contender: contender,
            backend: .postgres,
            reopenDatabase: {
                PostgresDatabase(
                    configuration: primaryConfiguration,
                    maxConnections: 1
                )
            }
        )
        await primary.shutdown()
        await contender.shutdown()
    } catch {
        await primary.shutdown()
        await contender.shutdown()
        throw error
    }
}

private func runMigratorSharedConformance(
    primary: any ExclusiveTransactionDatabase,
    contender: any ExclusiveTransactionDatabase,
    backend: SharedConformanceBackend,
    reopenDatabase: @escaping @Sendable () -> any ExclusiveTransactionDatabase
) async throws {
    let tables = SharedConformanceTables()

    do {
        try await sharedDropTables(tables.all, from: primary)
        for tableName in tables.probes {
            try await sharedCreateProbeTable(tableName, in: primary)
        }

        // Open the second physical connection before contention begins.
        #expect(
            try await sharedRowCount(
                in: tables.sameProbe,
                database: contender
            ) == 0
        )

        try await assertSameNamespaceContention(
            primary: primary,
            contender: contender,
            backend: backend,
            trackingTable: tables.sameTracking,
            probeTable: tables.sameProbe
        )
        try await assertDifferentNamespacesSerialize(
            primary: primary,
            contender: contender,
            backend: backend,
            firstTrackingTable: tables.firstNamespaceTracking,
            secondTrackingTable: tables.secondNamespaceTracking,
            probeTable: tables.namespaceProbe
        )
        try await assertLiveHistoryDriftPreventsBody(
            database: primary,
            trackingTable: tables.driftTracking
        )
        try await assertMaskedTransactionControlRollsBack(
            database: primary,
            trackingTable: tables.controlTracking,
            probeTable: tables.controlProbe
        )
        try await assertTransactionControlBatchIsAtomic(
            database: primary,
            backend: backend,
            trackingTable: tables.batchTracking,
            probeTable: tables.batchProbe
        )
        try await assertShutdownReopenUsesTrackingHistory(
            trackingTable: tables.reopenTracking,
            probeTable: tables.reopenProbe,
            reopenDatabase: reopenDatabase
        )

        try await sharedDropTables(tables.all, from: primary)
    } catch {
        await sharedBestEffortDropTables(tables.all, from: primary)
        throw error
    }
}

private func assertSameNamespaceContention(
    primary: any ExclusiveTransactionDatabase,
    contender: any ExclusiveTransactionDatabase,
    backend: SharedConformanceBackend,
    trackingTable: String,
    probeTable: String
) async throws {
    let gate = SharedConformanceGate()
    let holderEntries = SharedConformanceCounter()
    let contenderEntries = SharedConformanceCounter()
    let reference = MigrationReference(
        position: 1,
        id: "001_same_namespace",
        revision: 1
    )
    let holderMigrator = try Migrator(
        database: primary,
        migrations: [
            Migration(id: reference.id) { context in
                await holderEntries.increment()
                try await sharedInsertProbe(
                    context: context,
                    table: probeTable,
                    position: 1,
                    marker: "holder"
                )
                await gate.hold()
            },
        ],
        trackingTableName: trackingTable
    )
    let contenderMigrator = try Migrator(
        database: contender,
        migrations: [
            Migration(id: reference.id) { _ in
                await contenderEntries.increment()
            },
        ],
        trackingTableName: trackingTable
    )
    let pendingStatus = MigrationStatus(applied: [], pending: [reference])

    // Commit the metadata table before contention so a schema lock cannot impersonate the
    // database-wide migration lock under test.
    #expect(try await holderMigrator.status() == pendingStatus)
    #expect(try await contenderMigrator.status() == pendingStatus)

    let holder = Task {
        try await holderMigrator.migrate()
    }

    do {
        try await sharedRequireHolderEntry(gate, operation: holder)
        try await expectSharedContention(backend: backend, holderGate: gate) {
            try await contenderMigrator.migrate()
        }
        #expect(await contenderEntries.value == 0)

        await gate.release()
        #expect(try await holder.value == MigrationReport(applied: [reference]))

        let retryReport = try await contenderMigrator.migrate()
        #expect(retryReport == MigrationReport(applied: []))
        #expect(await holderEntries.value == 1)
        #expect(await contenderEntries.value == 0)
        #expect(
            try await sharedProbeRows(in: probeTable, database: primary)
                == [SharedProbeRow(position: 1, marker: "holder")]
        )
        #expect(try await sharedRowCount(in: trackingTable, database: primary) == 1)
    } catch {
        await gate.release()
        holder.cancel()
        _ = try? await holder.value
        throw error
    }
}

private func assertDifferentNamespacesSerialize(
    primary: any ExclusiveTransactionDatabase,
    contender: any ExclusiveTransactionDatabase,
    backend: SharedConformanceBackend,
    firstTrackingTable: String,
    secondTrackingTable: String,
    probeTable: String
) async throws {
    let gate = SharedConformanceGate()
    let activity = SharedConformanceActivity()
    let firstReference = MigrationReference(
        position: 1,
        id: "001_first_namespace",
        revision: 1
    )
    let secondReference = MigrationReference(
        position: 1,
        id: "001_second_namespace",
        revision: 1
    )
    let firstMigrator = try Migrator(
        database: primary,
        migrations: [
            Migration(id: firstReference.id) { context in
                await activity.enter()
                do {
                    try await sharedInsertProbe(
                        context: context,
                        table: probeTable,
                        position: 1,
                        marker: "first"
                    )
                    await gate.hold()
                    await activity.leave()
                } catch {
                    await activity.leave()
                    throw error
                }
            },
        ],
        trackingTableName: firstTrackingTable
    )
    let secondMigrator = try Migrator(
        database: contender,
        migrations: [
            Migration(id: secondReference.id) { context in
                await activity.enter()
                do {
                    try await sharedInsertProbe(
                        context: context,
                        table: probeTable,
                        position: 2,
                        marker: "second"
                    )
                    await activity.leave()
                } catch {
                    await activity.leave()
                    throw error
                }
            },
        ],
        trackingTableName: secondTrackingTable
    )

    // Keep DDL and catalog locking outside the measured interval. Only the fixed migration lock
    // may prevent the second namespace body from entering while the first body is active.
    #expect(
        try await firstMigrator.status()
            == MigrationStatus(applied: [], pending: [firstReference])
    )
    #expect(
        try await secondMigrator.status()
            == MigrationStatus(applied: [], pending: [secondReference])
    )

    let holder = Task {
        try await firstMigrator.migrate()
    }

    do {
        try await sharedRequireHolderEntry(gate, operation: holder)
        try await expectSharedContention(backend: backend, holderGate: gate) {
            try await secondMigrator.migrate()
        }
        #expect(await activity.snapshot().active == 1)
        #expect(await activity.snapshot().completed == 0)

        await gate.release()
        #expect(try await holder.value == MigrationReport(applied: [firstReference]))

        let retryReport = try await secondMigrator.migrate()
        #expect(retryReport == MigrationReport(applied: [secondReference]))
        #expect(
            await activity.snapshot()
                == SharedActivitySnapshot(active: 0, maximumActive: 1, completed: 2)
        )
        #expect(
            try await sharedProbeRows(in: probeTable, database: primary)
                == [
                    SharedProbeRow(position: 1, marker: "first"),
                    SharedProbeRow(position: 2, marker: "second"),
                ]
        )
        #expect(try await sharedRowCount(in: firstTrackingTable, database: primary) == 1)
        #expect(try await sharedRowCount(in: secondTrackingTable, database: primary) == 1)
    } catch {
        await gate.release()
        holder.cancel()
        _ = try? await holder.value
        throw error
    }
}

private func assertLiveHistoryDriftPreventsBody(
    database: any ExclusiveTransactionDatabase,
    trackingTable: String
) async throws {
    let bodyEntries = SharedConformanceCounter()
    let expected = MigrationReference(
        position: 1,
        id: "001_expected_history",
        revision: 1
    )
    let actual = MigrationReference(
        position: 1,
        id: "001_actual_history",
        revision: 1
    )
    let migrator = try Migrator(
        database: database,
        migrations: [
            Migration(id: expected.id) { _ in
                await bodyEntries.increment()
            },
        ],
        trackingTableName: trackingTable
    )

    #expect(
        try await migrator.status()
            == MigrationStatus(applied: [], pending: [expected])
    )
    try await sharedInsertTrackingRow(
        actual,
        into: trackingTable,
        database: database
    )

    do {
        _ = try await migrator.migrate()
        Issue.record("migrate unexpectedly accepted live history drift")
    } catch let error as MigrationHistoryError {
        #expect(
            error == .appliedMigrationMismatch(
                expected: expected,
                actual: actual
            )
        )
    } catch {
        Issue.record("live history drift returned an unexpected error: \(error)")
    }

    #expect(await bodyEntries.value == 0)
    #expect(try await sharedRowCount(in: trackingTable, database: database) == 1)
}

private func assertMaskedTransactionControlRollsBack(
    database: any ExclusiveTransactionDatabase,
    trackingTable: String,
    probeTable: String
) async throws {
    let bodyEntries = SharedConformanceCounter()
    let reference = MigrationReference(
        position: 1,
        id: "001_masked_control",
        revision: 1
    )
    let migrator = try Migrator(
        database: database,
        migrations: [
            Migration(id: reference.id) { context in
                await bodyEntries.increment()
                try await sharedInsertProbe(
                    context: context,
                    table: probeTable,
                    position: 1,
                    marker: "must-roll-back"
                )
                _ = try await context.execute(
                    "; -- BEGIN is only a comment\n/* leading trivia */ COMMIT",
                    []
                )
            },
        ],
        trackingTableName: trackingTable
    )

    _ = try await migrator.status()
    do {
        _ = try await migrator.migrate()
        Issue.record("masked COMMIT unexpectedly escaped the migration boundary")
    } catch let error as MigrationExecutionError {
        #expect(error == .transactionControlNotAllowed(command: "COMMIT"))
    } catch {
        Issue.record("masked COMMIT returned an unexpected error: \(error)")
    }

    #expect(await bodyEntries.value == 1)
    #expect(try await sharedRowCount(in: probeTable, database: database) == 0)
    #expect(try await sharedRowCount(in: trackingTable, database: database) == 0)
}

private func assertTransactionControlBatchIsAtomic(
    database: any ExclusiveTransactionDatabase,
    backend: SharedConformanceBackend,
    trackingTable: String,
    probeTable: String
) async throws {
    let bodyEntries = SharedConformanceCounter()
    let reference = MigrationReference(
        position: 1,
        id: "001_control_batch",
        revision: 1
    )
    let table = database.dialect.quoteIdentifier(probeTable)
    let position = database.dialect.quoteIdentifier("position")
    let marker = database.dialect.quoteIdentifier("marker")
    let batch = """
        INSERT INTO \(table) (\(position), \(marker)) VALUES (1, 'must-not-run');
        COMMIT
        """
    let migrator = try Migrator(
        database: database,
        migrations: [
            Migration(id: reference.id) { context in
                await bodyEntries.increment()
                _ = try await context.execute(batch, [])
            },
        ],
        trackingTableName: trackingTable
    )

    _ = try await migrator.status()
    do {
        _ = try await migrator.migrate()
        Issue.record("INSERT/COMMIT batch unexpectedly executed")
    } catch {
        try backend.requireBatchRejection(error)
    }

    #expect(await bodyEntries.value == 1)
    #expect(try await sharedRowCount(in: probeTable, database: database) == 0)
    #expect(try await sharedRowCount(in: trackingTable, database: database) == 0)
}

private func assertShutdownReopenUsesTrackingHistory(
    trackingTable: String,
    probeTable: String,
    reopenDatabase: @escaping @Sendable () -> any ExclusiveTransactionDatabase
) async throws {
    let initial = reopenDatabase()
    let reference = MigrationReference(
        position: 1,
        id: "001_shutdown_reopen",
        revision: 1
    )
    let initialMigrator = try Migrator(
        database: initial,
        migrations: [
            Migration(id: reference.id) { context in
                try await sharedInsertProbe(
                    context: context,
                    table: probeTable,
                    position: 1,
                    marker: "persisted"
                )
            },
        ],
        trackingTableName: trackingTable
    )

    do {
        #expect(try await initialMigrator.migrate() == MigrationReport(applied: [reference]))
    } catch {
        await initial.shutdown()
        throw error
    }
    await initial.shutdown()

    let reopened = reopenDatabase()
    let reopenedBodyEntries = SharedConformanceCounter()
    let reopenedMigrator = try Migrator(
        database: reopened,
        migrations: [
            Migration(id: reference.id) { _ in
                await reopenedBodyEntries.increment()
            },
        ],
        trackingTableName: trackingTable
    )

    do {
        #expect(
            try await reopenedMigrator.status()
                == MigrationStatus(applied: [reference], pending: [])
        )
        #expect(try await reopenedMigrator.migrate() == MigrationReport(applied: []))
        #expect(await reopenedBodyEntries.value == 0)
        #expect(
            try await sharedProbeRows(in: probeTable, database: reopened)
                == [SharedProbeRow(position: 1, marker: "persisted")]
        )
        await reopened.shutdown()
    } catch {
        await reopened.shutdown()
        throw error
    }
}

private func expectSharedContention<T: Sendable>(
    backend: SharedConformanceBackend,
    holderGate: SharedConformanceGate,
    _ operation: () async throws -> T
) async throws {
    let watchdog = Task {
        do {
            try await Task.sleep(for: .seconds(5))
        } catch {
            return false
        }
        await holderGate.release()
        return true
    }

    do {
        _ = try await operation()
        watchdog.cancel()
        if await watchdog.value {
            throw SharedConformanceError.contentionWatchdogExpired
        }
        throw SharedConformanceError.contentionNotObserved
    } catch let error as SharedConformanceError {
        watchdog.cancel()
        _ = await watchdog.value
        throw error
    } catch {
        watchdog.cancel()
        if await watchdog.value {
            throw SharedConformanceError.contentionWatchdogExpired
        }
        try backend.requireContention(error)
    }
}

private func sharedRequireHolderEntry<T: Sendable>(
    _ gate: SharedConformanceGate,
    operation: Task<T, Error>
) async throws {
    let watchdog = Task {
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            return
        }
        await gate.abort()
    }
    await gate.waitUntilEntered()
    watchdog.cancel()
    await watchdog.value

    guard await gate.didEnter else {
        operation.cancel()
        _ = try? await operation.value
        throw SharedConformanceError.holderDidNotEnter
    }
}

private func sharedCreateProbeTable(
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

private func sharedInsertProbe(
    context: MigrationContext,
    table: String,
    position: Int64,
    marker: String
) async throws {
    let statement = try context.renderer.render(
        SQLInsert(
            table: table,
            values: [
                SQLColumnValue(column: "position", value: .int(position)),
                SQLColumnValue(column: "marker", value: .text(marker)),
            ]
        )
    )
    _ = try await context.execute(statement.sql, statement.parameters)
}

private func sharedInsertTrackingRow(
    _ reference: MigrationReference,
    into tableName: String,
    database: any Database
) async throws {
    let statement = try SQLRenderer(dialect: database.dialect).render(
        SQLInsert(
            table: tableName,
            values: [
                SQLColumnValue(column: "position", value: .int(reference.position)),
                SQLColumnValue(column: "id", value: .text(reference.id)),
                SQLColumnValue(column: "revision", value: .int(reference.revision)),
                SQLColumnValue(
                    column: "applied_at",
                    value: .date(
                        SQLTimestamp(
                            microsecondsSinceUnixEpoch: 1_700_000_000_000_000
                        )
                    )
                ),
            ]
        )
    )
    _ = try await database.execute(statement.sql, statement.parameters)
}

private func sharedProbeRows(
    in tableName: String,
    database: any Database
) async throws -> [SharedProbeRow] {
    let statement = try SQLRenderer(dialect: database.dialect).render(
        SQLSelect(
            table: tableName,
            columns: ["position", "marker"],
            orderings: [SQLOrdering(column: "position")]
        )
    )
    let result = try await database.execute(statement.sql, statement.parameters)
    return try result.rows.map { row in
        SharedProbeRow(
            position: try row.decode("position", as: Int64.self),
            marker: try row.decode("marker", as: String.self)
        )
    }
}

private func sharedRowCount(
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

private func sharedDropTables(
    _ tableNames: [String],
    from database: any Database
) async throws {
    for tableName in tableNames {
        let table = database.dialect.quoteIdentifier(tableName)
        _ = try await database.execute("DROP TABLE IF EXISTS \(table)", [])
    }
}

private func sharedBestEffortDropTables(
    _ tableNames: [String],
    from database: any Database
) async {
    for tableName in tableNames {
        let table = database.dialect.quoteIdentifier(tableName)
        _ = try? await database.execute("DROP TABLE IF EXISTS \(table)", [])
    }
}

private enum SharedConformanceBackend: Sendable {
    case sqlite
    case postgres

    func requireContention(_ error: any Error) throws {
        switch self {
        case .sqlite:
            guard let error = error as? PerunSQLite.PerunError,
                  let sqliteError = error.sqliteError,
                  sqliteError.resultCode.isBusy else {
                throw error
            }
        case .postgres:
            guard let error = error as? PerunPGSQL.PerunError,
                  case let .server(serverError) = error,
                  serverError.sqlState == .lockNotAvailable else {
                throw error
            }
        }
    }

    func requireBatchRejection(_ error: any Error) throws {
        switch self {
        case .sqlite:
            guard let error = error as? PerunSQLite.PerunError,
                  error == .multipleStatements else {
                throw error
            }
        case .postgres:
            guard let error = error as? PerunPGSQL.PerunError,
                  case let .server(serverError) = error,
                  serverError.sqlState == .syntaxError else {
                throw error
            }
        }
    }
}

private struct SharedConformanceTables {
    let sameTracking: String
    let sameProbe: String
    let firstNamespaceTracking: String
    let secondNamespaceTracking: String
    let namespaceProbe: String
    let driftTracking: String
    let controlTracking: String
    let controlProbe: String
    let batchTracking: String
    let batchProbe: String
    let reopenTracking: String
    let reopenProbe: String

    init() {
        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        sameTracking = "pm_same_t_\(suffix)"
        sameProbe = "pm_same_p_\(suffix)"
        firstNamespaceTracking = "pm_ns1_t_\(suffix)"
        secondNamespaceTracking = "pm_ns2_t_\(suffix)"
        namespaceProbe = "pm_ns_p_\(suffix)"
        driftTracking = "pm_drift_t_\(suffix)"
        controlTracking = "pm_ctrl_t_\(suffix)"
        controlProbe = "pm_ctrl_p_\(suffix)"
        batchTracking = "pm_batch_t_\(suffix)"
        batchProbe = "pm_batch_p_\(suffix)"
        reopenTracking = "pm_open_t_\(suffix)"
        reopenProbe = "pm_open_p_\(suffix)"

        precondition(
            all.allSatisfy { $0.utf8.count <= 63 },
            "shared conformance table names must remain portable"
        )
    }

    var probes: [String] {
        [sameProbe, namespaceProbe, controlProbe, batchProbe, reopenProbe]
    }

    var all: [String] {
        probes + [
            sameTracking,
            firstNamespaceTracking,
            secondNamespaceTracking,
            driftTracking,
            controlTracking,
            batchTracking,
            reopenTracking,
        ]
    }
}

private struct SharedProbeRow: Sendable, Equatable {
    let position: Int64
    let marker: String
}

private struct SharedActivitySnapshot: Sendable, Equatable {
    let active: Int
    let maximumActive: Int
    let completed: Int
}

private actor SharedConformanceCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor SharedConformanceActivity {
    private var active = 0
    private var maximumActive = 0
    private var completed = 0

    func enter() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func leave() {
        active -= 1
        completed += 1
    }

    func snapshot() -> SharedActivitySnapshot {
        SharedActivitySnapshot(
            active: active,
            maximumActive: maximumActive,
            completed: completed
        )
    }
}

private actor SharedConformanceGate {
    private var entered = false
    private var released = false
    private var aborted = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        guard !aborted else { return }
        entered = true
        let pendingEntryWaiters = entryWaiters
        entryWaiters.removeAll(keepingCapacity: false)
        for waiter in pendingEntryWaiters {
            waiter.resume()
        }

        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released || aborted {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilEntered() async {
        guard !entered, !aborted else { return }
        await withCheckedContinuation { continuation in
            if entered || aborted {
                continuation.resume()
            } else {
                entryWaiters.append(continuation)
            }
        }
    }

    func release() {
        guard !released else { return }
        released = true
        resumeReleaseWaiters()
    }

    func abort() {
        guard !aborted else { return }
        aborted = true
        let pendingEntryWaiters = entryWaiters
        entryWaiters.removeAll(keepingCapacity: false)
        for waiter in pendingEntryWaiters {
            waiter.resume()
        }
        resumeReleaseWaiters()
    }

    var didEnter: Bool {
        entered
    }

    private func resumeReleaseWaiters() {
        let pendingReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pendingReleaseWaiters {
            waiter.resume()
        }
    }
}

private enum SharedConformanceError: Error, Sendable {
    case contentionNotObserved
    case contentionWatchdogExpired
    case holderDidNotEnter
}

private func sharedConformancePostgresConfiguration(
    lockTimeout: String? = nil
) -> ConnectionConfiguration {
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

    var runtimeParameters: [String: String] = [:]
    if let lockTimeout {
        runtimeParameters["options"] = "-c lock_timeout=\(lockTimeout)"
    }

    return ConnectionConfiguration(
        host: environment["PGHOST"] ?? "localhost",
        port: UInt16(environment["PGPORT"] ?? "") ?? 5_432,
        user: environment["PGUSER"] ?? "perun",
        database: environment["PGDATABASE"] ?? "perun",
        password: environment["PGPASSWORD"],
        tlsMode: tlsMode,
        runtimeParameters: runtimeParameters
    )
}
