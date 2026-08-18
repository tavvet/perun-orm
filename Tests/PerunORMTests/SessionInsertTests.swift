import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
@testable import PerunORM
import Testing

@Test
func entitySchemaBuildsGeneratedAndAssignedInsertAST() throws {
    let generated = try EntitySchema(GeneratedInsertRecord.self)
    let generatedInput = GeneratedInsertRecord(
        id: 0,
        name: "draft",
        nickname: nil,
        isActive: true
    )

    #expect(generated.primaryKeyIsGenerated)
    #expect(
        generated.insertStatement(generatedInput, returning: false) == SQLInsert(
            table: "insert\"records",
            values: [
                SQLColumnValue(column: "name", value: .text("draft")),
                SQLColumnValue(column: "nickname", value: .null),
                SQLColumnValue(column: "is_active", value: .bool(true)),
            ]
        )
    )
    #expect(
        generated.insertStatement(generatedInput, returning: true) == SQLInsert(
            table: "insert\"records",
            values: [
                SQLColumnValue(column: "name", value: .text("draft")),
                SQLColumnValue(column: "nickname", value: .null),
                SQLColumnValue(column: "is_active", value: .bool(true)),
            ],
            returning: ["id", "name", "nickname", "is_active"]
        )
    )

    let assigned = try EntitySchema(AssignedInsertRecord.self)
    let assignedInput = AssignedInsertRecord(id: 41, name: "assigned")
    #expect(!assigned.primaryKeyIsGenerated)
    #expect(
        assigned.insertStatement(assignedInput, returning: false) == SQLInsert(
            table: "assigned_insert_records",
            values: [
                SQLColumnValue(column: "id", value: .int(41)),
                SQLColumnValue(column: "name", value: .text("assigned")),
            ]
        )
    )
}

@Test
func unitOfWorkInsertUsesReturningAndPromotesTheCommittedSnapshot() async throws {
    let state = InsertDatabaseState(transactionResults: [
        ExecResult(
            rows: [generatedInsertRow(id: 17, name: "returned")],
            rowsAffected: 1
        ),
    ])
    let session = Session(
        database: InsertDatabase(state: state, dialect: PostgresDialect())
    )
    let input = GeneratedInsertRecord(id: 0, name: "returned", nickname: nil, isActive: true)

    let inserted = try await session.withUnitOfWork { unitOfWork in
        let inserted = try await unitOfWork.insert(input)
        let found = try await unitOfWork.find(GeneratedInsertRecord.self, inserted.id)
        #expect(found == inserted)
        return inserted
    }

    #expect(inserted.id == 17)
    let cached = try await session.find(GeneratedInsertRecord.self, inserted.id)
    #expect(cached == inserted)
    #expect(await state.calls == [
        InsertDatabaseCall(
            scope: .transaction,
            sql: "INSERT INTO \"insert\"\"records\" (\"name\", \"nickname\", \"is_active\") VALUES ($1, $2, $3) RETURNING \"id\", \"name\", \"nickname\", \"is_active\"",
            parameters: [.text("returned"), .null, .bool(true)],
            intent: .arbitrary
        ),
    ])
}

@Test
func unitOfWorkInsertUsesSQLiteRowIDFallbackInsideTheTransaction() async throws {
    let state = InsertDatabaseState(transactionResults: [
        ExecResult(rowsAffected: 1, lastInsertRowID: 23),
        ExecResult(rows: [generatedInsertRow(id: 23, name: "fallback")]),
    ])
    let session = Session(
        database: InsertDatabase(state: state, dialect: SQLiteDialect())
    )
    let input = GeneratedInsertRecord(id: 0, name: "fallback", nickname: nil, isActive: true)

    let inserted = try await session.withUnitOfWork { unitOfWork in
        let inserted = try await unitOfWork.insert(input)
        let found = try await unitOfWork.find(GeneratedInsertRecord.self, inserted.id)
        #expect(found == inserted)
        return inserted
    }

    #expect(inserted.id == 23)
    let cached = try await session.find(GeneratedInsertRecord.self, inserted.id)
    #expect(cached == inserted)
    #expect(await state.calls == [
        InsertDatabaseCall(
            scope: .transaction,
            sql: "INSERT INTO \"insert\"\"records\" (\"name\", \"nickname\", \"is_active\") VALUES (?, ?, ?)",
            parameters: [.text("fallback"), .null, .bool(true)],
            intent: .generatedRowIDInsert
        ),
        InsertDatabaseCall(
            scope: .transaction,
            sql: "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"insert\"\"records\" WHERE \"id\" = ? LIMIT ?",
            parameters: [.int(23), .int(2)],
            intent: .arbitrary
        ),
    ])
}

@Test
func unitOfWorkFindLoadsOnceThroughTheTransactionAndPromotesOnCommit() async throws {
    let state = InsertDatabaseState(transactionResults: [
        ExecResult(rows: [generatedInsertRow(id: 29, name: "transactional")]),
    ])
    let session = Session(
        database: InsertDatabase(state: state, dialect: SQLiteDialect())
    )

    let loaded = try await session.withUnitOfWork { unitOfWork in
        let first = try #require(
            await unitOfWork.find(GeneratedInsertRecord.self, 29)
        )
        let second = try await unitOfWork.find(GeneratedInsertRecord.self, 29)
        #expect(second == first)
        return first
    }

    #expect(loaded.name == "transactional")
    #expect(try await session.find(GeneratedInsertRecord.self, 29) == loaded)
    #expect(await state.calls == [
        InsertDatabaseCall(
            scope: .transaction,
            sql: "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"insert\"\"records\" WHERE \"id\" = ? LIMIT ?",
            parameters: [.int(29), .int(2)],
            intent: .arbitrary
        ),
    ])
}

@Test
func unitOfWorkInsertSupportsAssignedKeysWithoutKeyRetrieval() async throws {
    let state = InsertDatabaseState(transactionResults: [
        ExecResult(rowsAffected: nil),
    ])
    let session = Session(
        database: InsertDatabase(state: state, dialect: SQLiteDialect())
    )
    let input = AssignedInsertRecord(id: 41, name: "assigned")

    let inserted = try await session.withUnitOfWork { unitOfWork in
        try await unitOfWork.insert(input)
    }

    #expect(inserted == input)
    #expect(try await session.find(AssignedInsertRecord.self, 41) == input)
    #expect(await state.calls == [
        InsertDatabaseCall(
            scope: .transaction,
            sql: "INSERT INTO \"assigned_insert_records\" (\"id\", \"name\") VALUES (?, ?)",
            parameters: [.int(41), .text("assigned")],
            intent: .arbitrary
        ),
    ])
}

@Test
func generatedInsertRejectsADialectWithoutASafeKeyRetrievalPath() async throws {
    let state = InsertDatabaseState(transactionResults: [])
    let session = Session(
        database: InsertDatabase(state: state, dialect: UnsupportedInsertDialect())
    )
    let input = GeneratedInsertRecord(id: 0, name: "unsupported", nickname: nil, isActive: true)

    do {
        let _: GeneratedInsertRecord = try await session.withUnitOfWork { unitOfWork in
            try await unitOfWork.insert(input)
        }
        Issue.record("generated insert used a dialect without a safe key retrieval path")
    } catch let error as ORMError {
        #expect(
            error == .generatedPrimaryKeyRetrievalUnsupported(
                table: "insert\"records"
            )
        )
    }
    #expect(await state.calls.isEmpty)
}

@Test
func generatedInsertRequiresOneReturnedRow() async throws {
    let state = InsertDatabaseState(transactionResults: [
        ExecResult(rows: [], rowsAffected: 1),
    ])
    let session = Session(
        database: InsertDatabase(state: state, dialect: PostgresDialect())
    )
    let input = GeneratedInsertRecord(id: 0, name: "missing", nickname: nil, isActive: true)

    do {
        let _: GeneratedInsertRecord = try await session.withUnitOfWork { unitOfWork in
            try await unitOfWork.insert(input)
        }
        Issue.record("generated insert accepted an empty RETURNING result")
    } catch let error as ORMError {
        #expect(
            error == .unexpectedInsertResultRowCount(
                table: "insert\"records",
                actual: 0
            )
        )
    }
}

@Test
func generatedInsertRequiresTheSQLiteRowIDHint() async throws {
    let state = InsertDatabaseState(transactionResults: [
        ExecResult(rowsAffected: 1),
    ])
    let session = Session(
        database: InsertDatabase(state: state, dialect: SQLiteDialect())
    )
    let input = GeneratedInsertRecord(id: 0, name: "missing", nickname: nil, isActive: true)

    do {
        let _: GeneratedInsertRecord = try await session.withUnitOfWork { unitOfWork in
            try await unitOfWork.insert(input)
        }
        Issue.record("generated insert accepted a missing rowid hint")
    } catch let error as ORMError {
        #expect(error == .generatedPrimaryKeyUnavailable(table: "insert\"records"))
    }
}

@Test
func commitFailureDoesNotPromoteTheUnitOfWorkOverlay() async throws {
    let state = InsertDatabaseState(
        transactionResults: [
            ExecResult(
                rows: [generatedInsertRow(id: 31, name: "rolled back")],
                rowsAffected: 1
            ),
        ],
        directResults: [ExecResult(rows: [])],
        failCommit: true
    )
    let session = Session(
        database: InsertDatabase(state: state, dialect: PostgresDialect())
    )
    let input = GeneratedInsertRecord(id: 0, name: "rolled back", nickname: nil, isActive: true)

    do {
        let _: GeneratedInsertRecord = try await session.withUnitOfWork { unitOfWork in
            try await unitOfWork.insert(input)
        }
        Issue.record("transaction unexpectedly committed")
    } catch let error as InsertTestError {
        #expect(error == .commitFailed)
    }

    let missing = try await session.find(GeneratedInsertRecord.self, 31)
    #expect(missing == nil)
    #expect(await state.calls.map(\.scope) == [.transaction, .direct])
}

@Test
func assignedInsertInvalidatesMatchingBaseIdentityWhenCommitOutcomeIsUnknown() async throws {
    let state = InsertDatabaseState(
        transactionResults: [
            ExecResult(
                rows: [assignedInsertRow(id: 41, name: "after-unknown-commit")],
                rowsAffected: 1
            ),
        ],
        directResults: [
            ExecResult(rows: [assignedInsertRow(id: 41, name: "before-insert")]),
            ExecResult(rows: [assignedInsertRow(id: 41, name: "after-unknown-commit")]),
        ],
        failCommit: true
    )
    let session = Session(
        database: InsertDatabase(state: state, dialect: PostgresDialect())
    )

    let before = try #require(
        await session.find(AssignedInsertRecord.self, 41)
    )
    #expect(before.name == "before-insert")

    do {
        let _: AssignedInsertRecord = try await session.withUnitOfWork { unitOfWork in
            try await unitOfWork.insert(
                AssignedInsertRecord(id: 41, name: "after-unknown-commit")
            )
        }
        Issue.record("assigned insert with an unknown commit outcome unexpectedly succeeded")
    } catch let error as InsertTestError {
        #expect(error == .commitFailed)
    }

    let refreshed = try #require(
        await session.find(AssignedInsertRecord.self, 41)
    )
    #expect(refreshed.name == "after-unknown-commit")
    #expect(await state.calls.map(\.scope) == [.direct, .transaction, .direct])
}

@Test
func rawExecutionInvalidatesBaseIdentityWhenCommitOutcomeIsUnknown() async throws {
    let state = InsertDatabaseState(
        transactionResults: [ExecResult(rowsAffected: 1)],
        directResults: [
            ExecResult(rows: [generatedInsertRow(id: 36, name: "before-raw")]),
            ExecResult(rows: [generatedInsertRow(id: 36, name: "after-unknown-commit")]),
        ],
        failCommit: true
    )
    let session = Session(
        database: InsertDatabase(state: state, dialect: PostgresDialect())
    )

    let before = try #require(
        await session.find(GeneratedInsertRecord.self, 36)
    )
    #expect(before.name == "before-raw")

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            _ = try await unitOfWork.execute(
                "UPDATE \"insert\"\"records\" SET \"name\" = $1 WHERE \"id\" = $2",
                [.text("after-unknown-commit"), .int(36)]
            )
        }
        Issue.record("transaction with an unknown commit outcome unexpectedly succeeded")
    } catch let error as InsertTestError {
        #expect(error == .commitFailed)
    }

    let refreshed = try #require(
        await session.find(GeneratedInsertRecord.self, 36)
    )
    #expect(refreshed.name == "after-unknown-commit")
    #expect(await state.calls.map(\.scope) == [.direct, .transaction, .direct])
}

@Test
func bodyFailureDoesNotPromoteTheUnitOfWorkOverlay() async throws {
    let state = InsertDatabaseState(
        transactionResults: [
            ExecResult(
                rows: [generatedInsertRow(id: 32, name: "aborted")],
                rowsAffected: 1
            ),
        ],
        directResults: [ExecResult(rows: [])]
    )
    let session = Session(
        database: InsertDatabase(state: state, dialect: PostgresDialect())
    )
    let input = GeneratedInsertRecord(id: 0, name: "aborted", nickname: nil, isActive: true)

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            _ = try await unitOfWork.insert(input)
            throw InsertTestError.bodyFailed
        }
        Issue.record("failing transaction body unexpectedly committed")
    } catch let error as InsertTestError {
        #expect(error == .bodyFailed)
    }

    let missing = try await session.find(GeneratedInsertRecord.self, 32)
    #expect(missing == nil)
    #expect(await state.calls.map(\.scope) == [.transaction, .direct])
}

@Test
func swallowedPostWriteFailureForcesTheUnitOfWorkToRollBack() async throws {
    let state = InsertDatabaseState(transactionResults: [
        ExecResult(rows: [], rowsAffected: 1),
    ])
    let session = Session(
        database: InsertDatabase(state: state, dialect: PostgresDialect())
    )
    let input = GeneratedInsertRecord(id: 0, name: "swallowed", nickname: nil, isActive: true)

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            do {
                _ = try await unitOfWork.insert(input)
                Issue.record("insert unexpectedly accepted an empty RETURNING result")
            } catch let error as ORMError {
                #expect(
                    error == .unexpectedInsertResultRowCount(
                        table: "insert\"records",
                        actual: 0
                    )
                )
            }

            do {
                _ = try await unitOfWork.find(GeneratedInsertRecord.self, 1)
                Issue.record("rollback-only unit of work accepted another operation")
            } catch let error as SessionError {
                #expect(error == .unitOfWorkRollbackOnly)
            }
        }
        Issue.record("unit of work committed after a swallowed post-write failure")
    } catch let error as SessionError {
        #expect(error == .unitOfWorkRollbackOnly)
    }

    #expect(await state.commits == 0)
}

@Test
func failedStartedOperationReturnedByTheBodyStillForcesRollback() async throws {
    let state = InsertDatabaseState(transactionResults: [
        ExecResult(rows: [], rowsAffected: 1),
    ])
    let session = Session(
        database: InsertDatabase(state: state, dialect: PostgresDialect())
    )
    let input = GeneratedInsertRecord(id: 0, name: "unawaited", nickname: nil, isActive: true)

    do {
        _ = try await session.withUnitOfWork { unitOfWork in
            let operation = Task {
                try await unitOfWork.insert(input)
            }
            await state.waitUntilTransactionExecutionStarts()
            return operation
        }
        Issue.record("unit of work committed after its started operation failed")
    } catch let error as SessionError {
        #expect(error == .unitOfWorkRollbackOnly)
    }

    #expect(await state.commits == 0)
}

@Test
func swallowedRawExecutorFailureAfterInsertForcesRollback() async throws {
    let state = InsertDatabaseState(
        transactionResults: [
            ExecResult(
                rows: [generatedInsertRow(id: 33, name: "raw-failure")],
                rowsAffected: 1
            ),
        ],
        directResults: [ExecResult(rows: [])]
    )
    let session = Session(
        database: InsertDatabase(state: state, dialect: PostgresDialect())
    )
    let input = GeneratedInsertRecord(id: 0, name: "raw-failure", nickname: nil, isActive: true)

    do {
        let _: GeneratedInsertRecord = try await session.withUnitOfWork { unitOfWork in
            let inserted = try await unitOfWork.insert(input)
            do {
                _ = try await unitOfWork.execute("broken")
                Issue.record("raw executor unexpectedly succeeded")
            } catch let error as InsertTestError {
                #expect(error == .unexpectedExecution)
            }
            return inserted
        }
        Issue.record("unit of work committed after a swallowed executor failure")
    } catch let error as SessionError {
        #expect(error == .unitOfWorkRollbackOnly)
    }

    let missing = try await session.find(GeneratedInsertRecord.self, 33)
    #expect(missing == nil)
    #expect(await state.commits == 0)
    #expect(await state.calls.map(\.scope) == [.transaction, .transaction, .direct])
}

@Test
func swallowedFindExecutorFailureForcesRollback() async throws {
    let state = InsertDatabaseState(transactionResults: [])
    let session = Session(
        database: InsertDatabase(state: state, dialect: PostgresDialect())
    )

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            do {
                _ = try await unitOfWork.find(GeneratedInsertRecord.self, 404)
                Issue.record("transactional find unexpectedly succeeded")
            } catch let error as InsertTestError {
                #expect(error == .unexpectedExecution)
            }
        }
        Issue.record("unit of work committed after a swallowed find executor failure")
    } catch let error as SessionError {
        #expect(error == .unitOfWorkRollbackOnly)
    }

    #expect(await state.commits == 0)
}

@Test
func transactionControlCannotEscapeTheUnitOfWorkBoundary() async throws {
    let state = InsertDatabaseState(transactionResults: [])
    let session = Session(
        database: InsertDatabase(state: state, dialect: PostgresDialect())
    )

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            do {
                _ = try await unitOfWork.execute(
                    "; /* outer /* nested */ comment */ -- boundary\n rOlLbAcK"
                )
                Issue.record("unit of work accepted transaction control")
            } catch let error as SessionError {
                #expect(
                    error == .transactionControlNotAllowed(command: "ROLLBACK")
                )
            }

            do {
                _ = try await unitOfWork.execute("after-rejected-rollback")
                Issue.record("unit of work remained usable after transaction control")
            } catch let error as SessionError {
                #expect(error == .unitOfWorkRollbackOnly)
            }
        }
        Issue.record("unit of work committed after rejected transaction control")
    } catch let error as SessionError {
        #expect(error == .unitOfWorkRollbackOnly)
    }

    #expect(await state.calls.isEmpty)
    #expect(await state.commits == 0)
}

@Test
func successfulRawExecutionDropsEarlierOverlayBeforePromotion() async throws {
    let state = InsertDatabaseState(
        transactionResults: [
            ExecResult(
                rows: [generatedInsertRow(id: 34, name: "deleted-by-raw")],
                rowsAffected: 1
            ),
            ExecResult(rowsAffected: 1),
        ],
        directResults: [ExecResult(rows: [])]
    )
    let session = Session(
        database: InsertDatabase(state: state, dialect: PostgresDialect())
    )
    let input = GeneratedInsertRecord(
        id: 0,
        name: "deleted-by-raw",
        nickname: nil,
        isActive: true
    )

    let inserted = try await session.withUnitOfWork { unitOfWork in
        let inserted = try await unitOfWork.insert(input)
        _ = try await unitOfWork.execute(
            "DELETE FROM \"insert\"\"records\" WHERE \"id\" = $1",
            [.int(inserted.id)]
        )
        return inserted
    }

    #expect(inserted.id == 34)
    #expect(try await session.find(GeneratedInsertRecord.self, inserted.id) == nil)
    #expect(await state.commits == 1)
    #expect(await state.calls.map(\.scope) == [.transaction, .transaction, .direct])
}

@Test
func rawExecutionBypassesBaseIdentityAndPromotesOnlyFreshSnapshots() async throws {
    let state = InsertDatabaseState(
        transactionResults: [
            ExecResult(rowsAffected: 1),
            ExecResult(rows: [generatedInsertRow(id: 35, name: "after-raw")]),
        ],
        directResults: [
            ExecResult(rows: [generatedInsertRow(id: 35, name: "before-raw")]),
        ]
    )
    let session = Session(
        database: InsertDatabase(state: state, dialect: PostgresDialect())
    )

    let before = try #require(
        await session.find(GeneratedInsertRecord.self, 35)
    )
    #expect(before.name == "before-raw")

    let after = try await session.withUnitOfWork { unitOfWork in
        _ = try await unitOfWork.execute(
            "UPDATE \"insert\"\"records\" SET \"name\" = $1 WHERE \"id\" = $2",
            [.text("after-raw"), .int(35)]
        )
        return try #require(
            await unitOfWork.find(GeneratedInsertRecord.self, 35)
        )
    }

    #expect(after.name == "after-raw")
    #expect(try await session.find(GeneratedInsertRecord.self, 35) == after)
    #expect(await state.commits == 1)
    #expect(await state.calls.map(\.scope) == [.direct, .transaction, .transaction])
}

@Test
func preWriteInsertFailureDoesNotPoisonTheUnitOfWork() async throws {
    let state = InsertDatabaseState(transactionResults: [
        ExecResult(rowsAffected: 0),
    ])
    let session = Session(
        database: InsertDatabase(state: state, dialect: UnsupportedInsertDialect())
    )
    let input = GeneratedInsertRecord(id: 0, name: "recoverable", nickname: nil, isActive: true)

    try await session.withUnitOfWork { unitOfWork in
        do {
            _ = try await unitOfWork.insert(input)
            Issue.record("generated insert unexpectedly found a key retrieval path")
        } catch let error as ORMError {
            #expect(
                error == .generatedPrimaryKeyRetrievalUnsupported(
                    table: "insert\"records"
                )
            )
        }

        _ = try await unitOfWork.execute("still-open")
    }

    #expect(await state.commits == 1)
    #expect(await state.calls == [
        InsertDatabaseCall(
            scope: .transaction,
            sql: "still-open",
            parameters: [],
            intent: .arbitrary
        ),
    ])
}

private struct GeneratedInsertRecord: Entity, Equatable {
    typealias PK = Int64

    let id: Int64
    let name: String
    let nickname: String?
    let isActive: Bool

    static let tableName = "insert\"records"
    static var fields: [FieldDescriptor<GeneratedInsertRecord>] {
        [
            FieldDescriptor(
                \GeneratedInsertRecord.id,
                column: "id",
                role: .primaryKey(generated: true)
            ),
            FieldDescriptor(\GeneratedInsertRecord.name, column: "name"),
            FieldDescriptor(\GeneratedInsertRecord.nickname, column: "nickname"),
            FieldDescriptor(\GeneratedInsertRecord.isActive, column: "is_active"),
        ]
    }

    init(id: Int64, name: String, nickname: String?, isActive: Bool) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.isActive = isActive
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
        name = try row.decode("name", as: String.self)
        nickname = try row.decode("nickname", as: String?.self)
        isActive = try row.decode("is_active", as: Bool.self)
    }
}

private struct AssignedInsertRecord: Entity, Equatable {
    typealias PK = Int64

    let id: Int64
    let name: String

    static let tableName = "assigned_insert_records"
    static var fields: [FieldDescriptor<AssignedInsertRecord>] {
        [
            FieldDescriptor(
                \AssignedInsertRecord.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\AssignedInsertRecord.name, column: "name"),
        ]
    }

    init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
        name = try row.decode("name", as: String.self)
    }
}

private func generatedInsertRow(id: Int64, name: String) -> InsertRow {
    InsertRow(values: [
        "id": .int(id),
        "name": .text(name),
        "nickname": .null,
        "is_active": .bool(true),
    ])
}

private func assignedInsertRow(id: Int64, name: String) -> InsertRow {
    InsertRow(values: [
        "id": .int(id),
        "name": .text(name),
    ])
}

private struct UnsupportedInsertDialect: SQLDialect {
    let capabilities: DialectCapabilities = []

    func placeholder(at position: Int) -> String {
        precondition(position > 0)
        return "?"
    }
}

private struct InsertDatabaseCall: Sendable, Equatable {
    enum Scope: Sendable, Equatable {
        case direct
        case transaction
    }

    let scope: Scope
    let sql: String
    let parameters: [SQLValue]
    let intent: ExecutionIntent
}

private actor InsertDatabaseState {
    private var transactionResults: [ExecResult]
    private var directResults: [ExecResult]
    private let failCommit: Bool
    private(set) var calls: [InsertDatabaseCall] = []
    private(set) var commits = 0
    private var transactionExecutionStarted = false
    private var transactionStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        transactionResults: [ExecResult],
        directResults: [ExecResult] = [],
        failCommit: Bool = false
    ) {
        self.transactionResults = transactionResults
        self.directResults = directResults
        self.failCommit = failCommit
    }

    func execute(
        scope: InsertDatabaseCall.Scope,
        sql: String,
        parameters: [SQLValue],
        intent: ExecutionIntent
    ) throws -> ExecResult {
        calls.append(
            InsertDatabaseCall(
                scope: scope,
                sql: sql,
                parameters: parameters,
                intent: intent
            )
        )
        switch scope {
        case .direct:
            guard !directResults.isEmpty else {
                throw InsertTestError.unexpectedExecution
            }
            return directResults.removeFirst()
        case .transaction:
            transactionExecutionStarted = true
            let waiters = transactionStartWaiters
            transactionStartWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
            guard !transactionResults.isEmpty else {
                throw InsertTestError.unexpectedExecution
            }
            return transactionResults.removeFirst()
        }
    }

    func waitUntilTransactionExecutionStarts() async {
        guard !transactionExecutionStarted else { return }
        await withCheckedContinuation { continuation in
            if transactionExecutionStarted {
                continuation.resume()
            } else {
                transactionStartWaiters.append(continuation)
            }
        }
    }

    func commit() throws {
        commits += 1
        if failCommit {
            throw InsertTestError.commitFailed
        }
    }
}

private struct InsertDatabase: Database {
    let state: InsertDatabaseState
    let configuredDialect: any SQLDialect

    init(state: InsertDatabaseState, dialect: any SQLDialect) {
        self.state = state
        configuredDialect = dialect
    }

    var dialect: any SQLDialect { configuredDialect }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await state.execute(
            scope: .direct,
            sql: sql,
            parameters: parameters,
            intent: intent
        )
    }

    func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        let result = try await body(InsertTransaction(state: state))
        try await state.commit()
        return result
    }

    func shutdown() async {}
}

private struct InsertTransaction: Transaction {
    let state: InsertDatabaseState

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await state.execute(
            scope: .transaction,
            sql: sql,
            parameters: parameters,
            intent: intent
        )
    }
}

private struct InsertRow: Row {
    let values: [String: SQLValue]

    func decode<T: SQLValueConvertible>(_ column: String, as type: T.Type) throws -> T {
        guard let value = values[column] else {
            throw InsertTestError.missingColumn(column)
        }
        return try T(sqlValue: value)
    }

    func decodeIfPresent<T: SQLValueConvertible>(
        _ column: String,
        as type: T.Type
    ) throws -> T? {
        guard let value = values[column] else {
            throw InsertTestError.missingColumn(column)
        }
        guard value != .null else { return nil }
        return try T(sqlValue: value)
    }
}

private enum InsertTestError: Error, Equatable {
    case bodyFailed
    case commitFailed
    case missingColumn(String)
    case unexpectedExecution
}
