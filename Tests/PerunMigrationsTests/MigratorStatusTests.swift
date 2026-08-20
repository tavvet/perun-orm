@testable import PerunMigrations
import PerunDBAL
import Testing

@Test
func migratorStatusUsesExclusiveTransactionAndReturnsFreshPlan() async throws {
    let bodyCalls = StatusBodyCalls()
    let state = StatusRecordingState(
        responses: [
            .success(ExecResult()),
            .success(ExecResult(rows: [])),
        ]
    )
    let database = StatusRecordingDatabase(
        state: state,
        dialect: StatusConditionalCreateDialect()
    )
    let migrator = try statusMigrator(
        database: database,
        specifications: [
            ("create_users", 1),
            ("backfill_users", 2),
        ],
        bodyCalls: bodyCalls
    )

    let status = try await migrator.status()

    #expect(
        status == MigrationStatus(
            applied: [],
            pending: [
                statusReference(1, "create_users", 1),
                statusReference(2, "backfill_users", 2),
            ]
        )
    )
    let callCount = await bodyCalls.count()
    #expect(callCount == 0)

    let events = await state.recordedEvents()
    #expect(
        events == [
            .exclusiveTransactionStarted(statusLockKey),
            .statement(
                sql: statusCreateTableSQL,
                parameters: [],
                intent: .arbitrary
            ),
            .statement(
                sql: statusSelectSQL,
                parameters: [],
                intent: .arbitrary
            ),
            .commitAttempted,
        ]
    )
}

@Test
func migratorStatusReturnsAnExactAppliedPrefixAndPendingSuffix() async throws {
    let bodyCalls = StatusBodyCalls()
    let state = StatusRecordingState(
        responses: [
            .success(ExecResult()),
            .success(
                ExecResult(
                    rows: [
                        statusHistoryRow(
                            position: 1,
                            id: "create_users",
                            revision: 1,
                            appliedAt: 1_000_000
                        ),
                        statusHistoryRow(
                            position: 2,
                            id: "backfill_users",
                            revision: 2,
                            appliedAt: 2_000_000
                        ),
                    ]
                )
            ),
        ]
    )
    let database = StatusRecordingDatabase(
        state: state,
        dialect: StatusConditionalCreateDialect()
    )
    let migrator = try statusMigrator(
        database: database,
        specifications: [
            ("create_users", 1),
            ("backfill_users", 2),
            ("index_users", 1),
        ],
        bodyCalls: bodyCalls
    )

    let status = try await migrator.status()

    #expect(
        status == MigrationStatus(
            applied: [
                statusReference(1, "create_users", 1),
                statusReference(2, "backfill_users", 2),
            ],
            pending: [
                statusReference(3, "index_users", 1),
            ]
        )
    )
    let callCount = await bodyCalls.count()
    #expect(callCount == 0)
}

@Test
func migratorStatusReturnsHistoryDriftWithoutWrappingIt() async throws {
    let actual = statusReference(1, "legacy_users", 1)
    let expected = statusReference(1, "create_users", 1)
    let bodyCalls = StatusBodyCalls()
    let state = StatusRecordingState(
        responses: [
            .success(ExecResult()),
            .success(
                ExecResult(
                    rows: [
                        statusHistoryRow(
                            position: actual.position,
                            id: actual.id,
                            revision: actual.revision,
                            appliedAt: 1_000_000
                        ),
                    ]
                )
            ),
        ]
    )
    let database = StatusRecordingDatabase(
        state: state,
        dialect: StatusConditionalCreateDialect()
    )
    let migrator = try statusMigrator(
        database: database,
        specifications: [("create_users", 1)],
        bodyCalls: bodyCalls
    )

    do {
        _ = try await migrator.status()
        Issue.record("status accepted drifted migration history")
    } catch let error as MigrationHistoryError {
        #expect(
            error == .appliedMigrationMismatch(
                expected: expected,
                actual: actual
            )
        )
    } catch {
        Issue.record("status wrapped history drift as an unexpected error: \(error)")
    }

    let callCount = await bodyCalls.count()
    #expect(callCount == 0)
    let events = await state.recordedEvents()
    #expect(events.last == .rollbackRequested)
}

@Test
func migratorStatusDecodesTheCompleteSnapshotBeforeReconcilingDrift() async throws {
    let bodyCalls = StatusBodyCalls()
    let state = StatusRecordingState(
        responses: [
            .success(ExecResult()),
            .success(
                ExecResult(
                    rows: [
                        statusHistoryRow(
                            position: 1,
                            id: "legacy_users",
                            revision: 1,
                            appliedAt: 1_000_000
                        ),
                        StatusRecordingRow(
                            values: [
                                "position": .int(2),
                                "id": .text("backfill_users"),
                                "revision": .int(1),
                            ]
                        ),
                    ]
                )
            ),
        ]
    )
    let database = StatusRecordingDatabase(
        state: state,
        dialect: StatusConditionalCreateDialect()
    )
    let migrator = try statusMigrator(
        database: database,
        specifications: [
            ("create_users", 1),
            ("backfill_users", 1),
        ],
        bodyCalls: bodyCalls
    )

    do {
        _ = try await migrator.status()
        Issue.record("status reconciled drift before decoding the complete snapshot")
    } catch let error as MigrationHistoryError {
        #expect(
            error == .malformedRow(
                rowOrdinal: 2,
                column: "applied_at",
                reason: .unreadable
            )
        )
    } catch {
        Issue.record("status wrapped malformed history as an unexpected error: \(error)")
    }

    let callCount = await bodyCalls.count()
    #expect(callCount == 0)
    let events = await state.recordedEvents()
    #expect(events.last == .rollbackRequested)
}

@Test
func migratorStatusPassesThroughExclusiveLockErrors() async throws {
    let state = StatusRecordingState(
        responses: [],
        lockError: .lockFailed
    )
    let database = StatusRecordingDatabase(
        state: state,
        dialect: StatusConditionalCreateDialect()
    )
    let migrator = try statusMigrator(database: database)

    await expectStatusError(.lockFailed) {
        try await migrator.status()
    }

    let events = await state.recordedEvents()
    #expect(events == [.exclusiveTransactionStarted(statusLockKey)])
}

@Test
func migratorStatusPassesThroughStatementErrors() async throws {
    let state = StatusRecordingState(
        responses: [
            .success(ExecResult()),
            .failure(.statementFailed),
        ]
    )
    let database = StatusRecordingDatabase(
        state: state,
        dialect: StatusConditionalCreateDialect()
    )
    let migrator = try statusMigrator(database: database)

    await expectStatusError(.statementFailed) {
        try await migrator.status()
    }

    let events = await state.recordedEvents()
    #expect(events.last == .rollbackRequested)
}

@Test
func migratorStatusPassesThroughCommitErrors() async throws {
    let state = StatusRecordingState(
        responses: [
            .success(ExecResult()),
            .success(ExecResult(rows: [])),
        ],
        commitError: .commitFailed
    )
    let database = StatusRecordingDatabase(
        state: state,
        dialect: StatusConditionalCreateDialect()
    )
    let migrator = try statusMigrator(database: database)

    await expectStatusError(.commitFailed) {
        try await migrator.status()
    }

    let events = await state.recordedEvents()
    #expect(events.suffix(2) == [.commitAttempted, .rollbackRequested])
}

@Test
func cancelledMigratorStatusDoesNotCallTheDatabase() async throws {
    let gate = StatusStartGate()
    let state = StatusRecordingState(responses: [])
    let database = StatusRecordingDatabase(
        state: state,
        dialect: StatusConditionalCreateDialect()
    )
    let migrator = try statusMigrator(database: database)

    let operation = Task {
        await gate.wait()
        return try await migrator.status()
    }
    operation.cancel()
    await gate.open()

    do {
        _ = try await operation.value
        Issue.record("a pre-cancelled status call unexpectedly succeeded")
    } catch is CancellationError {
        // Expected: Migrator observes cancellation before reading its database or dialect.
    } catch {
        Issue.record("a pre-cancelled status call threw an unexpected error: \(error)")
    }

    let events = await state.recordedEvents()
    #expect(events.isEmpty)
}

@Test
func unsupportedConditionalCreateDoesNotReachTheTransactionExecutor() async throws {
    let state = StatusRecordingState(responses: [])
    let database = StatusRecordingDatabase(
        state: state,
        dialect: StatusDefaultCreateDialect()
    )
    let migrator = try statusMigrator(database: database)

    do {
        _ = try await migrator.status()
        Issue.record("status accepted a dialect without conditional CREATE TABLE support")
    } catch let error as SQLDialectFeatureError {
        #expect(error == .createTableIfNotExistsUnsupported)
    } catch {
        Issue.record("status wrapped the dialect feature error: \(error)")
    }

    let events = await state.recordedEvents()
    #expect(
        events == [
            .exclusiveTransactionStarted(statusLockKey),
            .rollbackRequested,
        ]
    )
}

private let statusLockKey: Int64 = 2_311_701_755_587_480_641

private let statusCreateTableSQL =
    "CREATE TABLE IF NOT EXISTS \"_perun_migrations\" "
    + "(\"position\" BIGINT NOT NULL PRIMARY KEY, \"id\" TEXT NOT NULL UNIQUE, "
    + "\"revision\" BIGINT NOT NULL, "
    + "\"applied_at\" TIMESTAMP WITH TIME ZONE NOT NULL)"

private let statusSelectSQL =
    "SELECT \"position\", \"id\", \"revision\", \"applied_at\" "
    + "FROM \"_perun_migrations\" ORDER BY \"position\" ASC"

private func statusMigrator(
    database: StatusRecordingDatabase,
    specifications: [(id: String, revision: Int64)] = [],
    bodyCalls: StatusBodyCalls = StatusBodyCalls()
) throws -> Migrator {
    try Migrator(
        database: database,
        migrations: specifications.map { specification in
            Migration(
                id: specification.id,
                revision: specification.revision
            ) { _ in
                await bodyCalls.record()
            }
        }
    )
}

private func statusReference(
    _ position: Int64,
    _ id: String,
    _ revision: Int64
) -> MigrationReference {
    MigrationReference(position: position, id: id, revision: revision)
}

private func statusHistoryRow(
    position: Int64,
    id: String,
    revision: Int64,
    appliedAt: Int64
) -> any Row {
    StatusRecordingRow(
        values: [
            "position": .int(position),
            "id": .text(id),
            "revision": .int(revision),
            "applied_at": .date(
                SQLTimestamp(microsecondsSinceUnixEpoch: appliedAt)
            ),
        ]
    )
}

private func expectStatusError<T: Sendable>(
    _ expected: StatusSentinelError,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("status unexpectedly succeeded instead of throwing \(expected)")
    } catch let error as StatusSentinelError {
        #expect(error == expected)
    } catch {
        Issue.record("status wrapped \(expected) as an unexpected error: \(error)")
    }
}

private struct StatusConditionalCreateDialect: SQLDialect {
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

private struct StatusDefaultCreateDialect: SQLDialect {
    let capabilities: DialectCapabilities = []

    func placeholder(at position: Int) -> String {
        precondition(position > 0)
        return ":\(position)"
    }
}

private struct StatusRecordingDatabase: ExclusiveTransactionDatabase {
    let state: StatusRecordingState
    let dialectValue: any SQLDialect

    init(state: StatusRecordingState, dialect: any SQLDialect) {
        self.state = state
        dialectValue = dialect
    }

    var dialect: any SQLDialect {
        dialectValue
    }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        await state.record(.directDatabaseExecution)
        throw StatusSentinelError.unexpectedDirectDatabaseExecution
    }

    func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        _ = body
        await state.record(.ordinaryTransactionStarted)
        throw StatusSentinelError.unexpectedOrdinaryTransaction
    }

    func withExclusiveTransaction<T: Sendable>(
        lockKey: DatabaseLockKey,
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        try await state.beginExclusiveTransaction(lockKey: lockKey)

        do {
            let value = try await body(StatusRecordingTransaction(state: state))
            try await state.commit()
            return value
        } catch {
            await state.rollback()
            throw error
        }
    }

    func shutdown() async {}
}

private struct StatusRecordingTransaction: Transaction {
    let state: StatusRecordingState

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await state.execute(
            sql: sql,
            parameters: parameters,
            intent: intent
        )
    }
}

private actor StatusRecordingState {
    private var events: [StatusRecordingEvent] = []
    private var responses: [StatusExecutionResponse]
    private let lockError: StatusSentinelError?
    private let commitError: StatusSentinelError?

    init(
        responses: [StatusExecutionResponse],
        lockError: StatusSentinelError? = nil,
        commitError: StatusSentinelError? = nil
    ) {
        self.responses = responses
        self.lockError = lockError
        self.commitError = commitError
    }

    func beginExclusiveTransaction(lockKey: DatabaseLockKey) throws {
        events.append(.exclusiveTransactionStarted(lockKey.rawValue))
        if let lockError {
            throw lockError
        }
    }

    func execute(
        sql: String,
        parameters: [SQLValue],
        intent: ExecutionIntent
    ) throws -> ExecResult {
        events.append(
            .statement(
                sql: sql,
                parameters: parameters,
                intent: intent
            )
        )
        guard !responses.isEmpty else {
            throw StatusSentinelError.unexpectedStatement
        }

        switch responses.removeFirst() {
        case let .success(result):
            return result
        case let .failure(error):
            throw error
        }
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

    func record(_ event: StatusRecordingEvent) {
        events.append(event)
    }

    func recordedEvents() -> [StatusRecordingEvent] {
        events
    }
}

private enum StatusExecutionResponse: Sendable {
    case success(ExecResult)
    case failure(StatusSentinelError)
}

private enum StatusRecordingEvent: Sendable, Equatable {
    case exclusiveTransactionStarted(Int64)
    case statement(
        sql: String,
        parameters: [SQLValue],
        intent: ExecutionIntent
    )
    case commitAttempted
    case rollbackRequested
    case directDatabaseExecution
    case ordinaryTransactionStarted
}

private enum StatusSentinelError: Error, Sendable, Equatable {
    case lockFailed
    case statementFailed
    case commitFailed
    case unexpectedStatement
    case unexpectedDirectDatabaseExecution
    case unexpectedOrdinaryTransaction
}

private enum StatusRecordingRowError: Error, Sendable, Equatable {
    case missingColumn(String)
}

private struct StatusRecordingRow: Row {
    let values: [String: SQLValue]

    func decode<T: SQLValueConvertible>(
        _ column: String,
        as type: T.Type
    ) throws -> T {
        _ = type
        guard let value = values[column] else {
            throw StatusRecordingRowError.missingColumn(column)
        }
        return try T(sqlValue: value)
    }

    func decodeIfPresent<T: SQLValueConvertible>(
        _ column: String,
        as type: T.Type
    ) throws -> T? {
        _ = type
        guard let value = values[column] else {
            throw StatusRecordingRowError.missingColumn(column)
        }
        if case .null = value {
            return nil
        }
        return try T(sqlValue: value)
    }
}

private actor StatusBodyCalls {
    private var value = 0

    func record() {
        value += 1
    }

    func count() -> Int {
        value
    }
}

private actor StatusStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
