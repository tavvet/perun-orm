import PerunDBAL
@testable import PerunORM
import Testing

@Test
func entitySchemaBuildsDDLAndPrimaryKeyLookupAST() throws {
    let schema = try EntitySchema(FindUser.self)

    #expect(
        schema.createTableStatement == SQLCreateTable(
            table: "find\"users",
            columns: [
                SQLColumnDefinition(
                    name: "id",
                    type: .int64,
                    role: .primaryKey(generated: true)
                ),
                SQLColumnDefinition(name: "display\"name", type: .text, unique: true),
                SQLColumnDefinition(name: "nickname", type: .text, nullable: true),
            ]
        )
    )
    #expect(
        schema.findStatement(primaryKey: 7) == SQLSelect(
            table: "find\"users",
            columns: ["id", "display\"name", "nickname"],
            predicate: .comparison(column: "id", op: .eq, value: .int(7)),
            limit: 2
        )
    )
}

@Test
func sessionFindHydratesAndCachesASnapshot() async throws {
    let state = FindDatabaseState(results: [
        ExecResult(rows: [
            FindRow(values: [
                "id": .int(7),
                "display\"name": .text("before"),
                "nickname": .null,
            ]),
        ]),
    ])
    let session = Session(database: FindDatabase(state: state))

    let found = try await session.find(FindUser.self, 7)
    let loaded = try #require(found)
    #expect(loaded == FindUser(id: 7, displayName: "before", nickname: nil))

    let cachedResult = try await session.find(FindUser.self, 7)
    let cached = try #require(cachedResult)
    #expect(cached == loaded)

    let calls = await state.calls
    #expect(calls == [
        FindDatabaseCall(
            sql: "SELECT \"id\", \"display\"\"name\", \"nickname\" FROM \"find\"\"users\" WHERE \"id\" = ? FETCH FIRST ? ROWS ONLY",
            parameters: [.int(7), .int(2)],
            intent: .arbitrary
        ),
    ])
}

@Test
func sessionFindReturnsNilForAMissingRow() async throws {
    let state = FindDatabaseState(results: [ExecResult(rows: [])])
    let session = Session(database: FindDatabase(state: state))

    let missing = try await session.find(FindUser.self, 404)

    #expect(missing == nil)
    #expect(await state.calls.count == 1)
}

@Test
func sessionFindRejectsMultipleRowsForAPrimaryKey() async throws {
    let duplicate = FindRow(values: [
        "id": .int(7),
        "display\"name": .text("duplicate"),
        "nickname": .null,
    ])
    let state = FindDatabaseState(results: [
        ExecResult(rows: [duplicate, duplicate]),
    ])
    let session = Session(database: FindDatabase(state: state))

    do {
        _ = try await session.find(FindUser.self, 7)
        Issue.record("find accepted multiple rows for one primary key")
    } catch let error as ORMError {
        #expect(
            error == .multipleRowsForPrimaryKey(
                table: "find\"users",
                primaryKey: .int(7)
            )
        )
    }
}

@Test
func sessionFindRejectsMismatchedHydrationWithoutPoisoningTheCache() async throws {
    let state = FindDatabaseState(results: [
        ExecResult(rows: [
            FindRow(values: [
                "id": .int(8),
                "display\"name": .text("wrong"),
                "nickname": .null,
            ]),
        ]),
        ExecResult(rows: [
            FindRow(values: [
                "id": .int(7),
                "display\"name": .text("correct"),
                "nickname": .null,
            ]),
        ]),
    ])
    let session = Session(database: FindDatabase(state: state))

    do {
        _ = try await session.find(FindUser.self, 7)
        Issue.record("find cached an entity hydrated with a different primary key")
    } catch let error as ORMError {
        #expect(
            error == .hydratedPrimaryKeyMismatch(
                table: "find\"users",
                expected: .int(7),
                actual: .int(8)
            )
        )
    }

    let retried = try await session.find(FindUser.self, 7)
    let loaded = try #require(retried)
    #expect(loaded.displayName == "correct")
    #expect(await state.calls.count == 2)
}

@Test
func sessionFindValidatesTheEntitySchemaBeforeExecutingSQL() async throws {
    let state = FindDatabaseState(results: [])
    let session = Session(database: FindDatabase(state: state))

    do {
        _ = try await session.find(InvalidFindEntity.self, 1)
        Issue.record("find executed with an invalid entity schema")
    } catch let error as EntitySchemaError {
        #expect(error == .unsupportedPrimaryKeyType(.double))
    }
    #expect(await state.calls.isEmpty)
}

private struct FindUser: Entity, Equatable {
    typealias PK = Int64

    let id: Int64
    let displayName: String
    let nickname: String?

    static let tableName = "find\"users"
    static var fields: [FieldDescriptor<FindUser>] {
        [
            FieldDescriptor(\FindUser.id, column: "id", role: .primaryKey(generated: true)),
            FieldDescriptor(\FindUser.displayName, column: "display\"name", unique: true),
            FieldDescriptor(\FindUser.nickname, column: "nickname"),
        ]
    }

    init(id: Int64, displayName: String, nickname: String?) {
        self.id = id
        self.displayName = displayName
        self.nickname = nickname
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
        displayName = try row.decode("display\"name", as: String.self)
        nickname = try row.decode("nickname", as: String?.self)
    }
}

private struct InvalidFindEntity: Entity {
    typealias PK = Double

    let id: Double

    static let tableName = "invalid_find_entities"
    static var fields: [FieldDescriptor<InvalidFindEntity>] {
        [
            FieldDescriptor(
                \InvalidFindEntity.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
        ]
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Double.self)
    }
}

private struct FindDialect: SQLDialect {
    let capabilities: DialectCapabilities = []

    func placeholder(at position: Int) -> String {
        precondition(position > 0)
        return "?"
    }
}

private struct FindDatabaseCall: Sendable, Equatable {
    let sql: String
    let parameters: [SQLValue]
    let intent: ExecutionIntent
}

private actor FindDatabaseState {
    private var results: [ExecResult]
    private(set) var calls: [FindDatabaseCall] = []

    init(results: [ExecResult]) {
        self.results = results
    }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) throws -> ExecResult {
        calls.append(FindDatabaseCall(sql: sql, parameters: parameters, intent: intent))
        guard !results.isEmpty else {
            throw FindTestError.unexpectedExecution
        }
        return results.removeFirst()
    }
}

private struct FindDatabase: Database {
    let state: FindDatabaseState
    var dialect: any SQLDialect { FindDialect() }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await state.execute(sql, parameters, intent: intent)
    }

    func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        throw FindTestError.transactionsUnsupported
    }

    func shutdown() async {}
}

private struct FindRow: Row {
    let values: [String: SQLValue]

    func decode<T: SQLValueConvertible>(_ column: String, as type: T.Type) throws -> T {
        guard let value = values[column] else {
            throw FindTestError.missingColumn(column)
        }
        return try T(sqlValue: value)
    }

    func decodeIfPresent<T: SQLValueConvertible>(
        _ column: String,
        as type: T.Type
    ) throws -> T? {
        guard let value = values[column] else {
            throw FindTestError.missingColumn(column)
        }
        guard value != .null else { return nil }
        return try T(sqlValue: value)
    }
}

private enum FindTestError: Error {
    case missingColumn(String)
    case transactionsUnsupported
    case unexpectedExecution
}
