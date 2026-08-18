import PerunDBAL
import PerunDBALSQLite
@testable import PerunORM
import Testing

@Test
func entitySchemaBuildsDeleteASTForThePrimaryKey() throws {
    let schema = try EntitySchema(DeleteRecord.self)

    #expect(
        schema.deleteStatement(primaryKey: .int(7)) == SQLDelete(
            table: "delete\"records",
            predicate: .comparison(column: "id", op: .eq, value: .int(7))
        )
    )
}

@Test
func unitOfWorkDeleteStagesATombstoneAndRemovesCommittedIdentity() async throws {
    let before = DeleteRecord(id: 7, name: "before", isActive: true)
    let state = DeleteDatabaseState(
        transactionResults: [ExecResult(rowsAffected: nil)],
        directResults: [
            ExecResult(rows: [deleteRow(before)]),
            ExecResult(rows: []),
        ]
    )
    let session = Session(database: DeleteDatabase(state: state))
    let loaded = try #require(await session.find(DeleteRecord.self, 7))

    try await session.withUnitOfWork { unitOfWork in
        try await unitOfWork.delete(loaded)
        #expect(try await unitOfWork.find(DeleteRecord.self, 7) == nil)
        #expect(try await unitOfWork.find(DeleteRecord.self, 7) == nil)
    }

    #expect(try await session.find(DeleteRecord.self, 7) == nil)
    #expect(await state.commits == 1)
    #expect(await state.calls == [
        DeleteDatabaseCall(
            scope: .direct,
            sql: "SELECT \"id\", \"name\", \"is_active\" FROM \"delete\"\"records\" WHERE \"id\" = ? LIMIT ?",
            parameters: [.int(7), .int(2)]
        ),
        DeleteDatabaseCall(
            scope: .transaction,
            sql: "DELETE FROM \"delete\"\"records\" WHERE \"id\" = ?",
            parameters: [.int(7)]
        ),
        DeleteDatabaseCall(
            scope: .direct,
            sql: "SELECT \"id\", \"name\", \"is_active\" FROM \"delete\"\"records\" WHERE \"id\" = ? LIMIT ?",
            parameters: [.int(7), .int(2)]
        ),
    ])
}

@Test
func tombstoneCanBeReplacedByAnInsertInTheSameTransaction() async throws {
    let first = DeleteRecord(id: 11, name: "first", isActive: true)
    let replacement = DeleteRecord(id: 11, name: "replacement", isActive: false)
    let state = DeleteDatabaseState(transactionResults: [
        ExecResult(rowsAffected: 1),
        ExecResult(rowsAffected: 1),
        ExecResult(rowsAffected: 1),
    ])
    let session = Session(database: DeleteDatabase(state: state))

    let committed = try await session.withUnitOfWork { unitOfWork in
        let inserted = try await unitOfWork.insert(first)
        try await unitOfWork.delete(inserted)
        #expect(try await unitOfWork.find(DeleteRecord.self, 11) == nil)

        let reinserted = try await unitOfWork.insert(replacement)
        #expect(try await unitOfWork.find(DeleteRecord.self, 11) == replacement)
        return reinserted
    }

    #expect(committed == replacement)
    #expect(try await session.find(DeleteRecord.self, 11) == replacement)
    #expect(await state.commits == 1)
    #expect(await state.calls.map(\.scope) == [
        .transaction,
        .transaction,
        .transaction,
    ])
    #expect(await state.calls.map(\.parameters) == [
        [.int(11), .text("first"), .bool(true)],
        [.int(11)],
        [.int(11), .text("replacement"), .bool(false)],
    ])
}

@Test
func unitOfWorkDeleteRejectsADetachedSnapshotBeforeWrite() async throws {
    let detached = DeleteRecord(id: 13, name: "detached", isActive: true)
    let state = DeleteDatabaseState(transactionResults: [])
    let session = Session(database: DeleteDatabase(state: state))

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            try await unitOfWork.delete(detached)
        }
        Issue.record("delete accepted a detached snapshot")
    } catch let error as ORMError {
        #expect(
            error == .entityNotManaged(
                table: "delete\"records",
                primaryKey: .int(13)
            )
        )
    }

    #expect(await state.calls.isEmpty)
    #expect(await state.commits == 0)
}

@Test
func unitOfWorkDeleteRequiresTheLatestSnapshotAndRejectsASecondDelete() async throws {
    let before = DeleteRecord(id: 17, name: "before", isActive: true)
    let after = DeleteRecord(id: 17, name: "after", isActive: false)
    let state = DeleteDatabaseState(
        transactionResults: [
            ExecResult(rowsAffected: 1),
            ExecResult(rowsAffected: 1),
        ],
        directResults: [ExecResult(rows: [deleteRow(before)])]
    )
    let session = Session(database: DeleteDatabase(state: state))
    let loaded = try #require(await session.find(DeleteRecord.self, 17))

    try await session.withUnitOfWork { unitOfWork in
        let updated = try await unitOfWork.update(after, from: loaded)
        do {
            try await unitOfWork.delete(loaded)
            Issue.record("delete accepted a stale snapshot")
        } catch let error as ORMError {
            #expect(
                error == .staleEntitySnapshot(
                    table: "delete\"records",
                    primaryKey: .int(17)
                )
            )
        }

        try await unitOfWork.delete(updated)
        do {
            try await unitOfWork.delete(updated)
            Issue.record("delete accepted an existing tombstone as managed")
        } catch let error as ORMError {
            #expect(
                error == .entityNotManaged(
                    table: "delete\"records",
                    primaryKey: .int(17)
                )
            )
        }
        #expect(try await unitOfWork.find(DeleteRecord.self, 17) == nil)
    }

    #expect(await state.commits == 1)
    #expect(await state.calls.map(\.scope) == [.direct, .transaction, .transaction])
    #expect(await state.calls[1].parameters == [.text("after"), .bool(false), .int(17)])
    #expect(await state.calls[2].parameters == [.int(17)])
}

@Test
func swallowedMissingRowAfterDeleteForcesRollbackAndEvictsBaseIdentity() async throws {
    let before = DeleteRecord(id: 19, name: "before", isActive: true)
    let state = DeleteDatabaseState(
        transactionResults: [ExecResult(rowsAffected: 0)],
        directResults: [
            ExecResult(rows: [deleteRow(before)]),
            ExecResult(rows: [deleteRow(before)]),
        ]
    )
    let session = Session(database: DeleteDatabase(state: state))
    let loaded = try #require(await session.find(DeleteRecord.self, 19))

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            do {
                try await unitOfWork.delete(loaded)
                Issue.record("delete accepted rowsAffected == 0")
            } catch let error as ORMError {
                #expect(
                    error == .entityNotFound(
                        table: "delete\"records",
                        primaryKey: .int(19)
                    )
                )
            }
        }
        Issue.record("unit of work committed after a swallowed delete failure")
    } catch let error as SessionError {
        #expect(error == .unitOfWorkRollbackOnly)
    }

    #expect(try await session.find(DeleteRecord.self, 19) == before)
    #expect(await state.commits == 0)
    #expect(await state.calls.map(\.scope) == [.direct, .transaction, .direct])
}

@Test
func unitOfWorkDeleteRejectsMultipleAffectedRows() async throws {
    let before = DeleteRecord(id: 23, name: "before", isActive: true)
    let state = DeleteDatabaseState(
        transactionResults: [ExecResult(rowsAffected: 2)],
        directResults: [ExecResult(rows: [deleteRow(before)])]
    )
    let session = Session(database: DeleteDatabase(state: state))
    let loaded = try #require(await session.find(DeleteRecord.self, 23))

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            try await unitOfWork.delete(loaded)
        }
        Issue.record("delete accepted multiple affected rows")
    } catch let error as ORMError {
        #expect(
            error == .unexpectedDeleteAffectedRowCount(
                table: "delete\"records",
                primaryKey: .int(23),
                actual: 2
            )
        )
    }

    #expect(await state.commits == 0)
}

@Test
func commitFailureDoesNotPromoteTheDeletion() async throws {
    let before = DeleteRecord(id: 29, name: "before", isActive: true)
    let observedAfterFailure = DeleteRecord(
        id: 29,
        name: "database-outcome",
        isActive: false
    )
    let state = DeleteDatabaseState(
        transactionResults: [ExecResult(rowsAffected: 1)],
        directResults: [
            ExecResult(rows: [deleteRow(before)]),
            ExecResult(rows: [deleteRow(observedAfterFailure)]),
        ],
        failCommit: true
    )
    let session = Session(database: DeleteDatabase(state: state))
    let loaded = try #require(await session.find(DeleteRecord.self, 29))

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            try await unitOfWork.delete(loaded)
        }
        Issue.record("unit of work ignored a commit failure")
    } catch let error as DeleteTestError {
        #expect(error == .commitFailed)
    }

    #expect(try await session.find(DeleteRecord.self, 29) == observedAfterFailure)
    #expect(await state.commits == 1)
    #expect(await state.calls.map(\.scope) == [.direct, .transaction, .direct])
}

private struct DeleteRecord: Entity, Equatable {
    typealias PK = Int64

    let id: Int64
    let name: String
    let isActive: Bool

    static let tableName = "delete\"records"
    static var fields: [FieldDescriptor<DeleteRecord>] {
        [
            FieldDescriptor(
                \DeleteRecord.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\DeleteRecord.name, column: "name"),
            FieldDescriptor(\DeleteRecord.isActive, column: "is_active"),
        ]
    }

    init(id: Int64, name: String, isActive: Bool) {
        self.id = id
        self.name = name
        self.isActive = isActive
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
        name = try row.decode("name", as: String.self)
        isActive = try row.decode("is_active", as: Bool.self)
    }
}

private func deleteRow(_ record: DeleteRecord) -> DeleteRow {
    DeleteRow(values: [
        "id": .int(record.id),
        "name": .text(record.name),
        "is_active": .bool(record.isActive),
    ])
}

private struct DeleteDatabaseCall: Sendable, Equatable {
    enum Scope: Sendable, Equatable {
        case direct
        case transaction
    }

    let scope: Scope
    let sql: String
    let parameters: [SQLValue]
}

private actor DeleteDatabaseState {
    private var transactionResults: [ExecResult]
    private var directResults: [ExecResult]
    private let failCommit: Bool
    private(set) var calls: [DeleteDatabaseCall] = []
    private(set) var commits = 0

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
        scope: DeleteDatabaseCall.Scope,
        sql: String,
        parameters: [SQLValue]
    ) throws -> ExecResult {
        calls.append(DeleteDatabaseCall(scope: scope, sql: sql, parameters: parameters))
        switch scope {
        case .direct:
            guard !directResults.isEmpty else {
                throw DeleteTestError.unexpectedExecution
            }
            return directResults.removeFirst()
        case .transaction:
            guard !transactionResults.isEmpty else {
                throw DeleteTestError.unexpectedExecution
            }
            return transactionResults.removeFirst()
        }
    }

    func commit() throws {
        commits += 1
        if failCommit {
            throw DeleteTestError.commitFailed
        }
    }
}

private struct DeleteDatabase: Database {
    let state: DeleteDatabaseState
    let dialect: any SQLDialect = SQLiteDialect()

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await state.execute(scope: .direct, sql: sql, parameters: parameters)
    }

    func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        let result = try await body(DeleteTransaction(state: state))
        try await state.commit()
        return result
    }

    func shutdown() async {}
}

private struct DeleteTransaction: Transaction {
    let state: DeleteDatabaseState

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await state.execute(scope: .transaction, sql: sql, parameters: parameters)
    }
}

private struct DeleteRow: Row {
    let values: [String: SQLValue]

    func decode<T: SQLValueConvertible>(_ column: String, as type: T.Type) throws -> T {
        guard let value = values[column] else {
            throw DeleteTestError.missingColumn(column)
        }
        return try T(sqlValue: value)
    }

    func decodeIfPresent<T: SQLValueConvertible>(
        _ column: String,
        as type: T.Type
    ) throws -> T? {
        guard let value = values[column] else {
            throw DeleteTestError.missingColumn(column)
        }
        guard value != .null else { return nil }
        return try T(sqlValue: value)
    }
}

private enum DeleteTestError: Error, Equatable {
    case commitFailed
    case missingColumn(String)
    case unexpectedExecution
}
