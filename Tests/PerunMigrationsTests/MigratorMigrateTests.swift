import Foundation
import PerunDBAL
@testable import PerunMigrations
import Testing

@Test
func migratorAppliesFreshPlanInExactOrderAndCommitsReport() async throws {
    let firstTimestamp = SQLTimestamp(microsecondsSinceUnixEpoch: 1_700_000_000_111_111)
    let secondTimestamp = SQLTimestamp(microsecondsSinceUnixEpoch: 1_700_000_000_222_222)
    let first = migrateReference(1, "001_create_users", 1)
    let second = migrateReference(2, "002_backfill_users", 3)
    let clock = MigrateClockProbe([firstTimestamp, secondTimestamp])
    let state = MigrateRecordingState(
        executions: [
            migrateExecution(migrateCreateTableSQL),
            migrateExecution(migrateSelectSQL, result: ExecResult(rows: [])),
            migrateExecution("BODY A", parameters: [.text("users")]),
            migrateTrackingExecution(reference: first, appliedAt: firstTimestamp),
            migrateExecution("BODY B", parameters: [.int(42)]),
            migrateTrackingExecution(reference: second, appliedAt: secondTimestamp),
            migrateExecution(
                migrateSelectSQL,
                result: ExecResult(
                    rows: [
                        migrateHistoryRow(reference: first, appliedAt: firstTimestamp),
                        migrateHistoryRow(reference: second, appliedAt: secondTimestamp),
                    ]
                )
            ),
        ]
    )
    let migrator = try migrateMigrator(
        state: state,
        clock: clock,
        migrations: [
            Migration(id: first.id, revision: first.revision) { context in
                _ = try await context.execute("BODY A", [.text("users")])
            },
            Migration(id: second.id, revision: second.revision) { context in
                _ = try await context.execute("BODY B", [.int(42)])
            },
        ]
    )

    let report = try await migrator.migrate()

    #expect(report == MigrationReport(applied: [first, second]))
    #expect(clock.invocationCount == 2)
    #expect(await state.remainingExecutionCount() == 0)
    #expect(
        await state.recordedEvents() == [
            .exclusiveTransactionStarted(migrateLockKey),
            .statement(migrateStatement(migrateCreateTableSQL)),
            .statement(migrateStatement(migrateSelectSQL)),
            .statement(migrateStatement("BODY A", parameters: [.text("users")])),
            .statement(migrateTrackingStatement(reference: first, appliedAt: firstTimestamp)),
            .statement(migrateStatement("BODY B", parameters: [.int(42)])),
            .statement(migrateTrackingStatement(reference: second, appliedAt: secondTimestamp)),
            .statement(migrateStatement(migrateSelectSQL)),
            .commitAttempted,
        ]
    )
}

@Test
func migratorNoOpSkipsBodiesTrackingClockAndFinalReread() async throws {
    let firstTimestamp = SQLTimestamp(microsecondsSinceUnixEpoch: 1_600_000_000_111_111)
    let secondTimestamp = SQLTimestamp(microsecondsSinceUnixEpoch: 1_600_000_000_222_222)
    let first = migrateReference(1, "001_create_users", 1)
    let second = migrateReference(2, "002_backfill_users", 3)
    let bodyProbe = MigrateBodyProbe()
    let clock = MigrateClockProbe([SQLTimestamp(microsecondsSinceUnixEpoch: 9_999_999)])
    let state = MigrateRecordingState(
        executions: [
            migrateExecution(migrateCreateTableSQL),
            migrateExecution(
                migrateSelectSQL,
                result: ExecResult(
                    rows: [
                        migrateHistoryRow(reference: first, appliedAt: firstTimestamp),
                        migrateHistoryRow(reference: second, appliedAt: secondTimestamp),
                    ]
                )
            ),
        ]
    )
    let migrator = try migrateMigrator(
        state: state,
        clock: clock,
        migrations: [
            probeMigration(reference: first, bodyProbe: bodyProbe),
            probeMigration(reference: second, bodyProbe: bodyProbe),
        ]
    )

    let report = try await migrator.migrate()

    #expect(report == MigrationReport(applied: []))
    #expect(await bodyProbe.recordedIDs().isEmpty)
    #expect(clock.invocationCount == 0)
    #expect(await state.remainingExecutionCount() == 0)
    #expect(
        await state.recordedEvents() == [
            .exclusiveTransactionStarted(migrateLockKey),
            .statement(migrateStatement(migrateCreateTableSQL)),
            .statement(migrateStatement(migrateSelectSQL)),
            .commitAttempted,
        ]
    )
}

@Test
func migratorAppendRunsOnlyPendingMigrationAtFullPlanPosition() async throws {
    let firstTimestamp = SQLTimestamp(microsecondsSinceUnixEpoch: 1_600_000_000_111_111)
    let secondTimestamp = SQLTimestamp(microsecondsSinceUnixEpoch: 1_600_000_000_222_222)
    let thirdTimestamp = SQLTimestamp(microsecondsSinceUnixEpoch: 1_700_000_000_333_333)
    let first = migrateReference(1, "001_create_users", 1)
    let second = migrateReference(2, "002_backfill_users", 3)
    let third = migrateReference(3, "003_index_users", 2)
    let bodyProbe = MigrateBodyProbe()
    let clock = MigrateClockProbe([thirdTimestamp])
    let state = MigrateRecordingState(
        executions: [
            migrateExecution(migrateCreateTableSQL),
            migrateExecution(
                migrateSelectSQL,
                result: ExecResult(
                    rows: [
                        migrateHistoryRow(reference: first, appliedAt: firstTimestamp),
                        migrateHistoryRow(reference: second, appliedAt: secondTimestamp),
                    ]
                )
            ),
            migrateExecution("BODY C", parameters: [.text("index")]),
            migrateTrackingExecution(reference: third, appliedAt: thirdTimestamp),
            migrateExecution(
                migrateSelectSQL,
                result: ExecResult(
                    rows: [
                        migrateHistoryRow(reference: first, appliedAt: firstTimestamp),
                        migrateHistoryRow(reference: second, appliedAt: secondTimestamp),
                        migrateHistoryRow(reference: third, appliedAt: thirdTimestamp),
                    ]
                )
            ),
        ]
    )
    let migrator = try migrateMigrator(
        state: state,
        clock: clock,
        migrations: [
            probeMigration(reference: first, bodyProbe: bodyProbe),
            probeMigration(reference: second, bodyProbe: bodyProbe),
            Migration(id: third.id, revision: third.revision) { context in
                _ = try await context.execute("BODY C", [.text("index")])
            },
        ]
    )

    let report = try await migrator.migrate()

    #expect(report == MigrationReport(applied: [third]))
    #expect(await bodyProbe.recordedIDs().isEmpty)
    #expect(clock.invocationCount == 1)
    #expect(await state.remainingExecutionCount() == 0)
    #expect(
        await state.recordedEvents() == [
            .exclusiveTransactionStarted(migrateLockKey),
            .statement(migrateStatement(migrateCreateTableSQL)),
            .statement(migrateStatement(migrateSelectSQL)),
            .statement(migrateStatement("BODY C", parameters: [.text("index")])),
            .statement(migrateTrackingStatement(reference: third, appliedAt: thirdTimestamp)),
            .statement(migrateStatement(migrateSelectSQL)),
            .commitAttempted,
        ]
    )
}

@Test
func migratorBodyFailureRollsBackWithoutFinalReadAndPreservesOriginalError() async throws {
    let firstTimestamp = SQLTimestamp(microsecondsSinceUnixEpoch: 1_700_000_000_111_111)
    let first = migrateReference(1, "001_create_users", 1)
    let second = migrateReference(2, "002_backfill_users", 1)
    let clock = MigrateClockProbe([firstTimestamp])
    let state = MigrateRecordingState(
        executions: [
            migrateExecution(migrateCreateTableSQL),
            migrateExecution(migrateSelectSQL, result: ExecResult(rows: [])),
            migrateExecution("BODY A"),
            migrateTrackingExecution(reference: first, appliedAt: firstTimestamp),
            migrateExecution("BODY B"),
        ]
    )
    let migrator = try migrateMigrator(
        state: state,
        clock: clock,
        migrations: [
            Migration(id: first.id) { context in
                _ = try await context.execute("BODY A", [])
            },
            Migration(id: second.id) { context in
                _ = try await context.execute("BODY B", [])
                throw MigrateSentinelError.bodyBFailed
            },
        ]
    )

    await expectMigrateSentinel(.bodyBFailed) {
        try await migrator.migrate()
    }

    #expect(clock.invocationCount == 1)
    #expect(await state.remainingExecutionCount() == 0)
    #expect(
        await state.recordedEvents() == [
            .exclusiveTransactionStarted(migrateLockKey),
            .statement(migrateStatement(migrateCreateTableSQL)),
            .statement(migrateStatement(migrateSelectSQL)),
            .statement(migrateStatement("BODY A")),
            .statement(migrateTrackingStatement(reference: first, appliedAt: firstTimestamp)),
            .statement(migrateStatement("BODY B")),
            .rollbackRequested,
        ]
    )
}

@Test
func migratorCommitFailureDoesNotReturnAReport() async throws {
    let timestamp = SQLTimestamp(microsecondsSinceUnixEpoch: 1_700_000_000_111_111)
    let reference = migrateReference(1, "001_create_users", 1)
    let clock = MigrateClockProbe([timestamp])
    let state = MigrateRecordingState(
        executions: [
            migrateExecution(migrateCreateTableSQL),
            migrateExecution(migrateSelectSQL, result: ExecResult(rows: [])),
            migrateExecution("BODY A"),
            migrateTrackingExecution(reference: reference, appliedAt: timestamp),
            migrateExecution(
                migrateSelectSQL,
                result: ExecResult(
                    rows: [migrateHistoryRow(reference: reference, appliedAt: timestamp)]
                )
            ),
        ],
        commitError: .commitFailed
    )
    let migrator = try migrateMigrator(
        state: state,
        clock: clock,
        migrations: [
            Migration(id: reference.id) { context in
                _ = try await context.execute("BODY A", [])
            },
        ]
    )

    await expectMigrateSentinel(.commitFailed) {
        try await migrator.migrate()
    }

    #expect(clock.invocationCount == 1)
    #expect(await state.remainingExecutionCount() == 0)
    #expect(
        await state.recordedEvents().suffix(2) == [
            .commitAttempted,
            .rollbackRequested,
        ]
    )
}

@Test
func migratorInitialHistoryDriftStopsBeforePendingBody() async throws {
    let expected = migrateReference(1, "001_create_users", 1)
    let actual = migrateReference(1, "001_legacy_users", 1)
    let persistedTimestamp = SQLTimestamp(microsecondsSinceUnixEpoch: 1_600_000_000_111_111)
    let bodyProbe = MigrateBodyProbe()
    let clock = MigrateClockProbe([SQLTimestamp(microsecondsSinceUnixEpoch: 9_999_999)])
    let state = MigrateRecordingState(
        executions: [
            migrateExecution(migrateCreateTableSQL),
            migrateExecution(
                migrateSelectSQL,
                result: ExecResult(
                    rows: [
                        migrateHistoryRow(reference: actual, appliedAt: persistedTimestamp),
                    ]
                )
            ),
        ]
    )
    let migrator = try migrateMigrator(
        state: state,
        clock: clock,
        migrations: [probeMigration(reference: expected, bodyProbe: bodyProbe)]
    )

    do {
        _ = try await migrator.migrate()
        Issue.record("migrate accepted drifted initial history")
    } catch let error as MigrationHistoryError {
        #expect(error == .appliedMigrationMismatch(expected: expected, actual: actual))
    } catch {
        Issue.record("migrate wrapped initial history drift: \(error)")
    }

    #expect(await bodyProbe.recordedIDs().isEmpty)
    #expect(clock.invocationCount == 0)
    #expect(await state.remainingExecutionCount() == 0)
    #expect(
        await state.recordedEvents() == [
            .exclusiveTransactionStarted(migrateLockKey),
            .statement(migrateStatement(migrateCreateTableSQL)),
            .statement(migrateStatement(migrateSelectSQL)),
            .rollbackRequested,
        ]
    )
}

@Test(arguments: MigrateFinalSnapshotMismatch.allCases)
func migratorRejectsChangedFinalMetadataSnapshot(
    _ mismatch: MigrateFinalSnapshotMismatch
) async throws {
    let timestamp = SQLTimestamp(microsecondsSinceUnixEpoch: 1_700_000_000_111_111)
    let reference = migrateReference(1, "001_create_users", 1)
    let clock = MigrateClockProbe([timestamp])
    let finalRows = mismatch.rows(expected: reference, appliedAt: timestamp)
    let state = MigrateRecordingState(
        executions: [
            migrateExecution(migrateCreateTableSQL),
            migrateExecution(migrateSelectSQL, result: ExecResult(rows: [])),
            migrateExecution("BODY A"),
            migrateTrackingExecution(reference: reference, appliedAt: timestamp),
            migrateExecution(migrateSelectSQL, result: ExecResult(rows: finalRows)),
        ]
    )
    let migrator = try migrateMigrator(
        state: state,
        clock: clock,
        migrations: [
            Migration(id: reference.id) { context in
                _ = try await context.execute("BODY A", [])
            },
        ]
    )

    do {
        _ = try await migrator.migrate()
        Issue.record("migrate accepted a changed final metadata snapshot")
    } catch let error as MigrationHistoryError {
        #expect(error == .reservedMetadataChanged)
    } catch {
        Issue.record("migrate wrapped reserved metadata mutation: \(error)")
    }

    #expect(clock.invocationCount == 1)
    #expect(await state.remainingExecutionCount() == 0)
    #expect(
        await state.recordedEvents().suffix(2) == [
            .statement(migrateStatement(migrateSelectSQL)),
            .rollbackRequested,
        ]
    )
}

@Test
func cancelledMigratorAfterLockDoesNotInvokeTransactionBodyWork() async throws {
    let reference = migrateReference(1, "001_create_users", 1)
    let bodyProbe = MigrateBodyProbe()
    let clock = MigrateClockProbe([
        SQLTimestamp(microsecondsSinceUnixEpoch: 1_700_000_000_111_111),
    ])
    let transactionBodyGate = MigrateTransactionBodyGate()
    let state = MigrateRecordingState(executions: [])
    let migrator = try migrateMigrator(
        state: state,
        clock: clock,
        migrations: [probeMigration(reference: reference, bodyProbe: bodyProbe)],
        transactionBodyGate: transactionBodyGate
    )
    let operation = Task {
        try await migrator.migrate()
    }

    await transactionBodyGate.waitUntilBlocked()
    operation.cancel()
    await transactionBodyGate.release()

    do {
        _ = try await operation.value
        Issue.record(
            "migrate unexpectedly succeeded after cancellation while waiting for its lock"
        )
    } catch is CancellationError {
        // Expected: the protected body checks cancellation before metadata SQL.
    } catch {
        Issue.record("cancelled migrate returned an unexpected error: \(error)")
    }

    #expect(await bodyProbe.recordedIDs().isEmpty)
    #expect(clock.invocationCount == 0)
    #expect(await state.remainingExecutionCount() == 0)
    #expect(
        await state.recordedEvents() == [
            .exclusiveTransactionStarted(migrateLockKey),
            .rollbackRequested,
        ]
    )
}

private let migrateLockKey: Int64 = 2_311_701_755_587_480_641

private let migrateCreateTableSQL =
    "CREATE TABLE IF NOT EXISTS \"_perun_migrations\" "
    + "(\"position\" BIGINT NOT NULL PRIMARY KEY, \"id\" TEXT NOT NULL UNIQUE, "
    + "\"revision\" BIGINT NOT NULL, "
    + "\"applied_at\" TIMESTAMP WITH TIME ZONE NOT NULL)"

private let migrateSelectSQL =
    "SELECT \"position\", \"id\", \"revision\", \"applied_at\" "
    + "FROM \"_perun_migrations\" ORDER BY \"position\" ASC"

private let migrateInsertSQL =
    "INSERT INTO \"_perun_migrations\" "
    + "(\"position\", \"id\", \"revision\", \"applied_at\") "
    + "VALUES (:1, :2, :3, :4)"

private func migrateMigrator(
    state: MigrateRecordingState,
    clock: MigrateClockProbe,
    migrations: [Migration],
    transactionBodyGate: MigrateTransactionBodyGate? = nil
) throws -> Migrator {
    try Migrator(
        database: MigrateRecordingDatabase(
            state: state,
            transactionBodyGate: transactionBodyGate
        ),
        migrations: migrations,
        clock: MigrationClock { clock.now() }
    )
}

private func probeMigration(
    reference: MigrationReference,
    bodyProbe: MigrateBodyProbe
) -> Migration {
    Migration(id: reference.id, revision: reference.revision) { _ in
        await bodyProbe.record(reference.id)
    }
}

private func migrateReference(
    _ position: Int64,
    _ id: String,
    _ revision: Int64
) -> MigrationReference {
    MigrationReference(position: position, id: id, revision: revision)
}

private func migrateExecution(
    _ sql: String,
    parameters: [SQLValue] = [],
    result: ExecResult = ExecResult()
) -> MigrateExpectedExecution {
    MigrateExpectedExecution(
        statement: migrateStatement(sql, parameters: parameters),
        result: result
    )
}

private func migrateTrackingExecution(
    reference: MigrationReference,
    appliedAt: SQLTimestamp
) -> MigrateExpectedExecution {
    MigrateExpectedExecution(
        statement: migrateTrackingStatement(reference: reference, appliedAt: appliedAt),
        result: ExecResult(rowsAffected: 1)
    )
}

private func migrateStatement(
    _ sql: String,
    parameters: [SQLValue] = []
) -> MigrateRecordedStatement {
    MigrateRecordedStatement(sql: sql, parameters: parameters, intent: .arbitrary)
}

private func migrateTrackingStatement(
    reference: MigrationReference,
    appliedAt: SQLTimestamp
) -> MigrateRecordedStatement {
    migrateStatement(
        migrateInsertSQL,
        parameters: [
            .int(reference.position),
            .text(reference.id),
            .int(reference.revision),
            .date(appliedAt),
        ]
    )
}

private func migrateHistoryRow(
    reference: MigrationReference,
    appliedAt: SQLTimestamp
) -> any Row {
    MigrateRecordingRow(
        values: [
            "position": .int(reference.position),
            "id": .text(reference.id),
            "revision": .int(reference.revision),
            "applied_at": .date(appliedAt),
        ]
    )
}

private func expectMigrateSentinel<T: Sendable>(
    _ expected: MigrateSentinelError,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("migrate unexpectedly succeeded instead of throwing \(expected)")
    } catch let error as MigrateSentinelError {
        #expect(error == expected)
    } catch {
        Issue.record("migrate wrapped \(expected) as an unexpected error: \(error)")
    }
}

enum MigrateFinalSnapshotMismatch: CaseIterable, Sendable {
    case deletedRow
    case updatedRow
    case extraRow
    case changedAppliedAt

    func rows(
        expected: MigrationReference,
        appliedAt: SQLTimestamp
    ) -> [any Row] {
        switch self {
        case .deletedRow:
            return []
        case .updatedRow:
            return [
                migrateHistoryRow(
                    reference: migrateReference(
                        expected.position,
                        expected.id,
                        expected.revision + 1
                    ),
                    appliedAt: appliedAt
                ),
            ]
        case .extraRow:
            return [
                migrateHistoryRow(reference: expected, appliedAt: appliedAt),
                migrateHistoryRow(
                    reference: migrateReference(2, "002_unexpected", 1),
                    appliedAt: appliedAt
                ),
            ]
        case .changedAppliedAt:
            return [
                migrateHistoryRow(
                    reference: expected,
                    appliedAt: SQLTimestamp(
                        microsecondsSinceUnixEpoch:
                            (appliedAt.microsecondsSinceUnixEpoch ?? 0) + 1
                    )
                ),
            ]
        }
    }
}

private struct MigrateDialect: SQLDialect {
    let capabilities: DialectCapabilities = []

    func placeholder(at position: Int) -> String {
        precondition(position > 0)
        return ":\(position)"
    }

    func createTableHead(ifNotExists: Bool) -> String {
        if ifNotExists {
            return "CREATE TABLE IF NOT EXISTS"
        }
        return "CREATE TABLE"
    }
}

private struct MigrateRecordingDatabase: ExclusiveTransactionDatabase {
    let state: MigrateRecordingState
    let transactionBodyGate: MigrateTransactionBodyGate?

    var dialect: any SQLDialect {
        MigrateDialect()
    }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        _ = sql
        _ = parameters
        _ = intent
        throw MigrateHarnessError.unexpectedDirectExecution
    }

    func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        _ = body
        throw MigrateHarnessError.unexpectedOrdinaryTransaction
    }

    func withExclusiveTransaction<T: Sendable>(
        lockKey: DatabaseLockKey,
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        await state.beginExclusiveTransaction(lockKey: lockKey)
        if let transactionBodyGate {
            await transactionBodyGate.waitBeforeInvokingBody()
        }
        do {
            let value = try await body(MigrateRecordingTransaction(state: state))
            try await state.commit()
            return value
        } catch {
            await state.rollback()
            throw error
        }
    }

    func shutdown() async {}
}

private actor MigrateTransactionBodyGate {
    private var isBlocked = false
    private var isReleased = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitBeforeInvokingBody() async {
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

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let currentReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in currentReleaseWaiters {
            waiter.resume()
        }
    }
}

private struct MigrateRecordingTransaction: Transaction {
    let state: MigrateRecordingState

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await state.execute(
            MigrateRecordedStatement(
                sql: sql,
                parameters: parameters,
                intent: intent
            )
        )
    }
}

private actor MigrateRecordingState {
    private var executions: [MigrateExpectedExecution]
    private var events: [MigrateRecordingEvent] = []
    private let commitError: MigrateSentinelError?

    init(
        executions: [MigrateExpectedExecution],
        commitError: MigrateSentinelError? = nil
    ) {
        self.executions = executions
        self.commitError = commitError
    }

    func beginExclusiveTransaction(lockKey: DatabaseLockKey) {
        events.append(.exclusiveTransactionStarted(lockKey.rawValue))
    }

    func execute(_ statement: MigrateRecordedStatement) throws -> ExecResult {
        events.append(.statement(statement))
        guard !executions.isEmpty else {
            throw MigrateHarnessError.unexpectedStatement(
                expected: nil,
                actual: statement
            )
        }
        let execution = executions.removeFirst()
        guard execution.statement == statement else {
            throw MigrateHarnessError.unexpectedStatement(
                expected: execution.statement,
                actual: statement
            )
        }
        return execution.result
    }

    func commit() throws {
        events.append(.commitAttempted)
        if let commitError {
            throw commitError
        }
    }

    func rollback() {
        events.append(.rollbackRequested)
    }

    func remainingExecutionCount() -> Int {
        executions.count
    }

    func recordedEvents() -> [MigrateRecordingEvent] {
        events
    }
}

private struct MigrateExpectedExecution: Sendable {
    let statement: MigrateRecordedStatement
    let result: ExecResult
}

private struct MigrateRecordedStatement: Sendable, Equatable {
    let sql: String
    let parameters: [SQLValue]
    let intent: ExecutionIntent
}

private enum MigrateRecordingEvent: Sendable, Equatable {
    case exclusiveTransactionStarted(Int64)
    case statement(MigrateRecordedStatement)
    case commitAttempted
    case rollbackRequested
}

private enum MigrateSentinelError: Error, Sendable, Equatable {
    case bodyBFailed
    case commitFailed
}

private enum MigrateHarnessError: Error, Sendable, Equatable {
    case unexpectedStatement(
        expected: MigrateRecordedStatement?,
        actual: MigrateRecordedStatement
    )
    case unexpectedDirectExecution
    case unexpectedOrdinaryTransaction
}

private enum MigrateRecordingRowError: Error, Sendable, Equatable {
    case missingColumn(String)
}

private struct MigrateRecordingRow: Row {
    let values: [String: SQLValue]

    func decode<T: SQLValueConvertible>(
        _ column: String,
        as type: T.Type
    ) throws -> T {
        _ = type
        guard let value = values[column] else {
            throw MigrateRecordingRowError.missingColumn(column)
        }
        return try T(sqlValue: value)
    }

    func decodeIfPresent<T: SQLValueConvertible>(
        _ column: String,
        as type: T.Type
    ) throws -> T? {
        _ = type
        guard let value = values[column] else {
            throw MigrateRecordingRowError.missingColumn(column)
        }
        if case .null = value {
            return nil
        }
        return try T(sqlValue: value)
    }
}

private actor MigrateBodyProbe {
    private var ids: [String] = []

    func record(_ id: String) {
        ids.append(id)
    }

    func recordedIDs() -> [String] {
        ids
    }
}

private final class MigrateClockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let timestamps: [SQLTimestamp]
    private var count = 0

    init(_ timestamps: [SQLTimestamp]) {
        precondition(!timestamps.isEmpty)
        self.timestamps = timestamps
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func now() -> SQLTimestamp {
        lock.lock()
        defer { lock.unlock() }
        let index = count
        count += 1
        return timestamps[min(index, timestamps.count - 1)]
    }
}
