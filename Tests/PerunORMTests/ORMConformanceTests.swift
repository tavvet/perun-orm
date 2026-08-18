import Foundation
import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
@testable import PerunORM
import PerunPGSQL
import PerunSQLite
import Testing

@Test
func sqlitePassesSharedORMFindConformance() async throws {
    try await runSharedORMFindConformance(
        database: SQLiteDatabase(configuration: .memory(), maxConnections: 1)
    )
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresPassesSharedORMFindConformance() async throws {
    try await runSharedORMFindConformance(
        database: PostgresDatabase(
            configuration: ormPostgresIntegrationConfiguration(),
            maxConnections: 1
        )
    )
}

private func runSharedORMFindConformance(database: any Database) async throws {
    let dialect = database.dialect
    let renderer = SQLRenderer(dialect: dialect)
    let tableName = ORMFindRecord.tableName
    let table = dialect.quoteIdentifier(tableName)
    let dropSQL = "DROP TABLE IF EXISTS \(table)"

    do {
        _ = try await database.execute(dropSQL, [])

        let schema = try EntitySchema(ORMFindRecord.self)
        let createTable = try renderer.render(schema.createTableStatement)
        _ = try await database.execute(createTable.sql, createTable.parameters)

        let inserted = try renderer.render(
            SQLInsert(
                table: tableName,
                values: [
                    SQLColumnValue(column: "id", value: .int(42)),
                    SQLColumnValue(column: "name", value: .text("before")),
                    SQLColumnValue(column: "nickname", value: .null),
                    SQLColumnValue(column: "is_active", value: .bool(true)),
                ]
            )
        )
        let insertResult = try await database.execute(inserted.sql, inserted.parameters)
        #expect(insertResult.rowsAffected == 1)

        let session = Session(database: database)
        let firstResult = try await session.find(ORMFindRecord.self, 42)
        let first = try #require(firstResult)
        #expect(
            first == ORMFindRecord(
                id: 42,
                name: "before",
                nickname: nil,
                isActive: true
            )
        )

        let updated = try renderer.render(
            SQLUpdate(
                table: tableName,
                assignments: [SQLColumnValue(column: "name", value: .text("after"))],
                predicate: .comparison(column: "id", op: .eq, value: .int(42))
            )
        )
        let updateResult = try await database.execute(updated.sql, updated.parameters)
        #expect(updateResult.rowsAffected == 1)

        let cachedResult = try await session.find(ORMFindRecord.self, 42)
        let cached = try #require(cachedResult)
        #expect(cached == first)

        let freshSession = Session(database: database)
        let refreshedResult = try await freshSession.find(ORMFindRecord.self, 42)
        let refreshed = try #require(refreshedResult)
        #expect(refreshed.name == "after")
        let missing = try await freshSession.find(ORMFindRecord.self, 404)
        #expect(missing == nil)

        _ = try await database.execute(dropSQL, [])
    } catch {
        _ = try? await database.execute(dropSQL, [])
        await database.shutdown()
        throw error
    }

    await database.shutdown()
}

private struct ORMFindRecord: Entity, Equatable {
    typealias PK = Int64

    let id: Int64
    let name: String
    let nickname: String?
    let isActive: Bool

    static let tableName = "perun_orm_find_"
        + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    static var fields: [FieldDescriptor<ORMFindRecord>] {
        [
            FieldDescriptor(
                \ORMFindRecord.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\ORMFindRecord.name, column: "name"),
            FieldDescriptor(\ORMFindRecord.nickname, column: "nickname"),
            FieldDescriptor(\ORMFindRecord.isActive, column: "is_active"),
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

private func ormPostgresIntegrationConfiguration() -> ConnectionConfiguration {
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
