import Foundation
import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
import PerunPGSQL
import PerunSQLite
import Testing

@Test
func sqlitePassesSharedDBALConformance() async throws {
    try await runSharedDBALConformance(
        database: SQLiteDatabase(configuration: .memory(), maxConnections: 1),
        schema: .sqlite
    )
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresPassesSharedDBALConformance() async throws {
    try await runSharedDBALConformance(
        database: PostgresDatabase(
            configuration: postgresIntegrationConfiguration(),
            maxConnections: 1
        ),
        schema: .postgres
    )
}

private func runSharedDBALConformance(
    database: any Database,
    schema: DBALConformanceSchema
) async throws {
    let dialect = database.dialect
    let tableName = "perun_dbal_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let table = dialect.quoteIdentifier(tableName)
    let columns = DBALConformanceColumns(dialect: dialect)
    let dropSQL = "DROP TABLE IF EXISTS \(table)"

    do {
        _ = try await database.execute(
            schema.createTableSQL(table: table, columns: columns),
            []
        )
        try await assertPortableBindingErrors(database: database, dialect: dialect)
        try await assertPortableRoundTrip(
            database: database,
            dialect: dialect,
            tableName: tableName,
            table: table,
            columns: columns
        )
        try await assertAffectedRowsAndTransactions(
            database: database,
            dialect: dialect,
            tableName: tableName,
            table: table,
            columns: columns
        )
        try await assertReturningCapability(
            database: database,
            dialect: dialect,
            tableName: tableName,
            table: table,
            columns: columns
        )
        _ = try await database.execute(dropSQL, [])
    } catch {
        _ = try? await database.execute(dropSQL, [])
        await database.shutdown()
        throw error
    }

    await database.shutdown()
}

private func assertPortableBindingErrors(
    database: any Database,
    dialect: any SQLDialect
) async throws {
    let selectParameter = "SELECT \(dialect.placeholder(at: 1))"

    do {
        _ = try await database.execute(selectParameter, [.double(.nan)])
        Issue.record("adapter unexpectedly bound NaN")
    } catch let error as SQLValueBindingError {
        #expect(error == .notANumber)
    }

    do {
        _ = try await database.execute(
            selectParameter,
            [Date(timeIntervalSinceReferenceDate: .infinity).sqlValue]
        )
        Issue.record("adapter unexpectedly bound a non-finite timestamp")
    } catch let error as SQLValueBindingError {
        #expect(error == .nonFiniteTimestamp)
    }
}

private func assertPortableRoundTrip(
    database: any Database,
    dialect: any SQLDialect,
    tableName: String,
    table: String,
    columns: DBALConformanceColumns
) async throws {
    let values = try DBALConformanceValues.make(id: 1, name: "Perun 🐺 'quoted'")
    try await assertContextFreeTypedParameterRoundTrip(
        database: database,
        dialect: dialect,
        columns: columns,
        values: values
    )

    let renderedInsert = try renderInsert(
        dialect: dialect,
        tableName: tableName,
        columns: columns,
        values: values
    )
    let insert = try await database.execute(renderedInsert.sql, renderedInsert.parameters)
    #expect(insert.rowsAffected == 1)
    #expect(insert.rows.isEmpty)
    #expect(insert.lastInsertRowID == nil)

    let renderedSelect = try SQLRenderer(dialect: dialect).render(
        SQLSelect(
            table: tableName,
            columns: columns.names,
            predicate: .and([
                .comparison(column: "id", op: .eq, value: .int(values.id)),
                .inList(column: "name", values: [.text(values.name), .null]),
            ]),
            orderings: [SQLOrdering(column: "id", direction: .descending)],
            limit: 1,
            offset: 0
        )
    )
    let selected = try await database.execute(renderedSelect.sql, renderedSelect.parameters)
    #expect(selected.rowsAffected == 0)
    #expect(selected.rows.count == 1)

    let row = try #require(selected.rows.first)
    #expect(try row.decode("id", as: Int64.self) == values.id)
    #expect(try row.decode("flag", as: Bool.self) == values.flag)
    #expect(try row.decode("small", as: Int32.self) == values.small)
    #expect(try row.decode("large", as: Int64.self) == values.large)
    #expect(try row.decode("score", as: Double.self).isInfinite)
    #expect(try row.decode("name", as: String.self) == values.name)
    #expect(try row.decodeIfPresent("name", as: String.self) == values.name)
    #expect(try row.decode("payload", as: [UInt8].self) == values.payload)
    #expect(try row.decode("created_at", as: Date.self).sqlValue == values.date.sqlValue)
    #expect(try row.decode("token", as: UUID.self) == values.token)
    #expect(try row.decode("absent", as: String?.self) == nil)
    #expect(try row.decodeIfPresent("absent", as: String.self) == nil)
    #expect(throws: SQLValueConversionError.self) {
        try row.decode("absent", as: String.self)
    }
    do {
        _ = try row.decode("name", as: Bool.self)
        Issue.record("adapter unexpectedly decoded text as Bool")
    } catch {
        #expect(error is SQLiteAdapterError || error is PostgresAdapterError)
    }
}

private func assertContextFreeTypedParameterRoundTrip(
    database: any Database,
    dialect: any SQLDialect,
    columns: DBALConformanceColumns,
    values: DBALConformanceValues
) async throws {
    let selected = try await database.execute(
        """
        SELECT \(dialect.placeholder(at: 1)) AS \(columns.flag),
               \(dialect.placeholder(at: 2)) AS \(columns.score),
               \(dialect.placeholder(at: 3)) AS \(columns.name),
               \(dialect.placeholder(at: 4)) AS \(columns.payload),
               \(dialect.placeholder(at: 5)) AS \(columns.createdAt),
               \(dialect.placeholder(at: 6)) AS \(columns.token)
        """,
        [
            values.flag.sqlValue,
            values.score.sqlValue,
            values.name.sqlValue,
            values.payload.sqlValue,
            values.date.sqlValue,
            values.token.sqlValue,
        ]
    )
    #expect(selected.rowsAffected == 0)
    #expect(selected.rows.count == 1)

    let row = try #require(selected.rows.first)
    #expect(try row.decode("flag", as: Bool.self) == values.flag)
    #expect(try row.decode("score", as: Double.self).isInfinite)
    #expect(try row.decode("name", as: String.self) == values.name)
    #expect(try row.decode("payload", as: [UInt8].self) == values.payload)
    #expect(try row.decode("created_at", as: Date.self).sqlValue == values.date.sqlValue)
    #expect(try row.decode("token", as: UUID.self) == values.token)
}

private func assertAffectedRowsAndTransactions(
    database: any Database,
    dialect: any SQLDialect,
    tableName: String,
    table: String,
    columns: DBALConformanceColumns
) async throws {
    let renderedUpdate = try renderUpdate(
        dialect: dialect,
        tableName: tableName,
        id: 1,
        name: "updated"
    )
    let updated = try await database.execute(renderedUpdate.sql, renderedUpdate.parameters)
    #expect(updated.rowsAffected == 1)
    let renderedMissingUpdate = try renderUpdate(
        dialect: dialect,
        tableName: tableName,
        id: 404,
        name: "missing"
    )
    let missing = try await database.execute(
        renderedMissingUpdate.sql,
        renderedMissingUpdate.parameters
    )
    #expect(missing.rowsAffected == 0)

    let committedValues = try DBALConformanceValues.make(id: 2, name: "committed")
    let committedInsert = try renderInsert(
        dialect: dialect,
        tableName: tableName,
        columns: columns,
        values: committedValues
    )
    let committedName = try await database.withTransaction { transaction in
        let result = try await transaction.execute(
            committedInsert.sql,
            committedInsert.parameters
        )
        #expect(result.rowsAffected == 1)
        let selected = try await transaction.execute(
            "SELECT \(columns.name) FROM \(table) WHERE \(columns.id) = \(dialect.placeholder(at: 1))",
            [.int(committedValues.id)]
        )
        let row = try #require(selected.rows.first)
        return try row.decode("name", as: String.self)
    }
    #expect(committedName == committedValues.name)

    let rolledBackValues = try DBALConformanceValues.make(id: 3, name: "rolled back")
    let rolledBackInsert = try renderInsert(
        dialect: dialect,
        tableName: tableName,
        columns: columns,
        values: rolledBackValues
    )
    do {
        let _: Void = try await database.withTransaction { transaction in
            _ = try await transaction.execute(
                rolledBackInsert.sql,
                rolledBackInsert.parameters
            )
            throw DBALConformanceRollback.expected
        }
        Issue.record("transaction unexpectedly committed")
    } catch DBALConformanceRollback.expected {
        // Expected: both drivers roll back when the transaction closure throws.
    }

    let countSQL = "SELECT COUNT(*) AS \(dialect.quoteIdentifier("count")) FROM \(table)"
    let countResult = try await database.execute(countSQL, [])
    let countRow = try #require(countResult.rows.first)
    #expect(try countRow.decode("count", as: Int64.self) == 2)

    let deleteSQL = "DELETE FROM \(table) WHERE \(columns.id) = \(dialect.placeholder(at: 1))"
    let deleted = try await database.execute(deleteSQL, [.int(2)])
    #expect(deleted.rowsAffected == 1)
    let deletedAgain = try await database.execute(deleteSQL, [.int(2)])
    #expect(deletedAgain.rowsAffected == 0)
}

private func renderInsert(
    dialect: any SQLDialect,
    tableName: String,
    columns: DBALConformanceColumns,
    values: DBALConformanceValues,
    returning: [String] = []
) throws -> RenderedSQL {
    let columnNames = columns.names
    let parameters = values.parameters
    try #require(columnNames.count == parameters.count)
    let columnValues = zip(columnNames, parameters).map { column, value in
        SQLColumnValue(column: column, value: value)
    }
    return try SQLRenderer(dialect: dialect).render(
        SQLInsert(table: tableName, values: columnValues, returning: returning)
    )
}

private func renderUpdate(
    dialect: any SQLDialect,
    tableName: String,
    id: Int64,
    name: String,
    returning: [String] = []
) throws -> RenderedSQL {
    try SQLRenderer(dialect: dialect).render(
        SQLUpdate(
            table: tableName,
            assignments: [SQLColumnValue(column: "name", value: .text(name))],
            predicate: .comparison(column: "id", op: .eq, value: .int(id)),
            returning: returning
        )
    )
}

private func assertReturningCapability(
    database: any Database,
    dialect: any SQLDialect,
    tableName: String,
    table: String,
    columns: DBALConformanceColumns
) async throws {
    guard dialect.capabilities.contains(.returning) else { return }

    let values = try DBALConformanceValues.make(id: 4, name: "returned")
    let rendered = try renderInsert(
        dialect: dialect,
        tableName: tableName,
        columns: columns,
        values: values,
        returning: ["id", "name"]
    )
    let result = try await database.execute(rendered.sql, rendered.parameters)
    #expect(result.rowsAffected == 1)
    #expect(result.rows.count == 1)
    #expect(result.lastInsertRowID == nil)

    let row = try #require(result.rows.first)
    #expect(try row.decode("id", as: Int64.self) == values.id)
    #expect(try row.decode("name", as: String.self) == values.name)

    let updatedName = "returned and updated"
    let renderedUpdate = try renderUpdate(
        dialect: dialect,
        tableName: tableName,
        id: values.id,
        name: updatedName,
        returning: ["id", "name"]
    )
    let updateResult = try await database.execute(
        renderedUpdate.sql,
        renderedUpdate.parameters
    )
    #expect(updateResult.rowsAffected == 1)
    #expect(updateResult.rows.count == 1)

    let updatedRow = try #require(updateResult.rows.first)
    #expect(try updatedRow.decode("id", as: Int64.self) == values.id)
    #expect(try updatedRow.decode("name", as: String.self) == updatedName)

    let deleteSQL = "DELETE FROM \(table) WHERE \(columns.id) = \(dialect.placeholder(at: 1))"
    let deleted = try await database.execute(deleteSQL, [.int(values.id)])
    #expect(deleted.rowsAffected == 1)
}

private struct DBALConformanceSchema: Sendable {
    let boolean: String
    let int32: String
    let int64: String
    let double: String
    let text: String
    let blob: String
    let timestamp: String
    let uuid: String

    static let sqlite = Self(
        boolean: "INTEGER",
        int32: "INTEGER",
        int64: "INTEGER",
        double: "REAL",
        text: "TEXT",
        blob: "BLOB",
        timestamp: "TEXT",
        uuid: "TEXT"
    )

    static let postgres = Self(
        boolean: "boolean",
        int32: "integer",
        int64: "bigint",
        double: "double precision",
        text: "text",
        blob: "bytea",
        timestamp: "timestamptz",
        uuid: "uuid"
    )

    func createTableSQL(table: String, columns: DBALConformanceColumns) -> String {
        """
        CREATE TABLE \(table) (
            \(columns.id) \(int64) PRIMARY KEY,
            \(columns.flag) \(boolean) NOT NULL,
            \(columns.small) \(int32) NOT NULL,
            \(columns.large) \(int64) NOT NULL,
            \(columns.score) \(double) NOT NULL,
            \(columns.name) \(text) NOT NULL,
            \(columns.payload) \(blob) NOT NULL,
            \(columns.createdAt) \(timestamp) NOT NULL,
            \(columns.token) \(uuid) NOT NULL,
            \(columns.absent) \(text)
        )
        """
    }
}

private struct DBALConformanceColumns: Sendable {
    let id: String
    let flag: String
    let small: String
    let large: String
    let score: String
    let name: String
    let payload: String
    let createdAt: String
    let token: String
    let absent: String

    init(dialect: any SQLDialect) {
        id = dialect.quoteIdentifier("id")
        flag = dialect.quoteIdentifier("flag")
        small = dialect.quoteIdentifier("small")
        large = dialect.quoteIdentifier("large")
        score = dialect.quoteIdentifier("score")
        name = dialect.quoteIdentifier("name")
        payload = dialect.quoteIdentifier("payload")
        createdAt = dialect.quoteIdentifier("created_at")
        token = dialect.quoteIdentifier("token")
        absent = dialect.quoteIdentifier("absent")
    }

    var list: String {
        [id, flag, small, large, score, name, payload, createdAt, token, absent]
            .joined(separator: ", ")
    }

    var names: [String] {
        ["id", "flag", "small", "large", "score", "name", "payload", "created_at", "token", "absent"]
    }

}

private struct DBALConformanceValues: Sendable {
    let id: Int64
    let flag: Bool
    let small: Int32
    let large: Int64
    let score: Double
    let name: String
    let payload: [UInt8]
    let date: Date
    let token: UUID

    static func make(id: Int64, name: String) throws -> Self {
        Self(
            id: id,
            flag: true,
            small: .min,
            large: .max,
            score: .infinity,
            name: name,
            payload: [0, 1, 2, 255],
            // Regression value: repeated Date-based normalization used to drift by 1 μs.
            date: Date(timeIntervalSince1970: 4_368_673_968.123_222),
            token: try #require(UUID(uuidString: "d7a42f38-c223-4f8c-bb11-cf304b086b3a"))
        )
    }

    var parameters: [SQLValue] {
        [
            .int(id),
            flag.sqlValue,
            small.sqlValue,
            large.sqlValue,
            score.sqlValue,
            name.sqlValue,
            payload.sqlValue,
            date.sqlValue,
            token.sqlValue,
            .null,
        ]
    }
}

private enum DBALConformanceRollback: Error {
    case expected
}

private func postgresIntegrationConfiguration() -> ConnectionConfiguration {
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
