import Foundation
import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
import PerunPGSQL
import PerunSQLite
import Testing

@Test
func sqlitePassesSingleStatementTransactionConformance() async throws {
    try await runSingleStatementTransactionConformance(
        database: SQLiteDatabase(configuration: .memory(), maxConnections: 1),
        backend: .sqlite
    )
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresPassesSingleStatementTransactionConformance() async throws {
    try await runSingleStatementTransactionConformance(
        database: PostgresDatabase(
            configuration: singleStatementPostgresConfiguration(),
            maxConnections: 1
        ),
        backend: .postgres
    )
}

private func runSingleStatementTransactionConformance(
    database: any Database,
    backend: SingleStatementBackend
) async throws {
    let dialect = database.dialect
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let tableName = "perun_single_statement_\(suffix)"
    let table = dialect.quoteIdentifier(tableName)
    let id = dialect.quoteIdentifier("id")
    let marker = dialect.quoteIdentifier("marker")
    let dropSQL = "DROP TABLE IF EXISTS \(table)"

    do {
        _ = try await database.execute(
            "CREATE TABLE \(table) (\(id) BIGINT NOT NULL PRIMARY KEY, \(marker) TEXT NOT NULL)",
            []
        )

        for path in SingleStatementExecutionPath.allCases {
            try await expectAtomicBatchRejection(
                database: database,
                backend: backend,
                path: path,
                sql: """
                INSERT INTO \(table) (\(id), \(marker)) VALUES (1, 'empty-first');
                INSERT INTO \(table) (\(id), \(marker)) VALUES (2, 'empty-second')
                """,
                parameters: []
            )
            try await expectNoRows(database: database, table: table)

            try await expectAtomicBatchRejection(
                database: database,
                backend: backend,
                path: path,
                sql: """
                INSERT INTO \(table) (\(id), \(marker)) VALUES (
                    \(dialect.placeholder(at: 1)), \(dialect.placeholder(at: 2))
                );
                INSERT INTO \(table) (\(id), \(marker)) VALUES (
                    \(dialect.placeholder(at: 3)), \(dialect.placeholder(at: 4))
                )
                """,
                parameters: [
                    .int(3),
                    .text("bound-first"),
                    .int(4),
                    .text("bound-second"),
                ]
            )
            try await expectNoRows(database: database, table: table)
        }

        let emptyStatementCases = [
            "",
            " \t\r\n ; ; ",
            "-- line comment\n/* block comment */;",
        ]
        let emptyStatementParameterCases: [[SQLValue]] = [
            [],
            [.text("unused")],
        ]
        for sql in emptyStatementCases {
            for parameters in emptyStatementParameterCases {
                for path in SingleStatementExecutionPath.allCases {
                    try await expectEmptyStatementRejection(
                        database: database,
                        backend: backend,
                        path: path,
                        sql: sql,
                        parameters: parameters
                    )
                    try await expectNoRows(database: database, table: table)
                }
            }
        }

        _ = try await database.execute(dropSQL, [])
    } catch {
        _ = try? await database.execute(dropSQL, [])
        await database.shutdown()
        throw error
    }

    await database.shutdown()
}

private func expectEmptyStatementRejection(
    database: any Database,
    backend: SingleStatementBackend,
    path: SingleStatementExecutionPath,
    sql: String,
    parameters: [SQLValue]
) async throws {
    do {
        switch path {
        case .database:
            _ = try await database.execute(sql, parameters)
        case .transaction:
            try await database.withTransaction { transaction in
                _ = try await transaction.execute(sql, parameters)
            }
        }
        Issue.record("\(path) unexpectedly accepted SQL without a meaningful statement")
    } catch {
        expectEmptyStatementError(error, backend: backend)
    }
}

private func expectAtomicBatchRejection(
    database: any Database,
    backend: SingleStatementBackend,
    path: SingleStatementExecutionPath,
    sql: String,
    parameters: [SQLValue]
) async throws {
    do {
        switch path {
        case .database:
            _ = try await database.execute(sql, parameters)
        case .transaction:
            try await database.withTransaction { transaction in
                _ = try await transaction.execute(sql, parameters)
            }
        }
        Issue.record("\(path) unexpectedly accepted a statement batch")
    } catch {
        expectOriginalDriverBatchError(error, backend: backend)
    }
}

private func expectNoRows(database: any Database, table: String) async throws {
    let result = try await database.execute("SELECT COUNT(*) AS row_count FROM \(table)", [])
    let row = try #require(result.rows.first)
    #expect(try row.decode("row_count", as: Int64.self) == 0)
}

private func expectOriginalDriverBatchError(
    _ error: any Error,
    backend: SingleStatementBackend
) {
    switch backend {
    case .sqlite:
        guard let error = error as? PerunSQLite.PerunError else {
            Issue.record("expected PerunSQLite.PerunError, got \(type(of: error)): \(error)")
            return
        }
        #expect(error == .multipleStatements)

    case .postgres:
        guard let error = error as? PerunPGSQL.PerunError else {
            Issue.record("expected PerunPGSQL.PerunError, got \(type(of: error)): \(error)")
            return
        }
        guard case let .server(serverError) = error else {
            Issue.record("expected PostgreSQL server error, got \(error)")
            return
        }
        #expect(serverError.sqlState == .syntaxError)
    }
}

private func expectEmptyStatementError(
    _ error: any Error,
    backend: SingleStatementBackend
) {
    switch backend {
    case .sqlite:
        guard let error = error as? PerunSQLite.PerunError else {
            Issue.record("expected PerunSQLite.PerunError, got \(type(of: error)): \(error)")
            return
        }
        #expect(error == .emptyStatement)

    case .postgres:
        guard let error = error as? PostgresStatementError else {
            Issue.record("expected PostgresStatementError, got \(type(of: error)): \(error)")
            return
        }
        #expect(error == .emptyStatement)
    }
}

private enum SingleStatementBackend: Sendable {
    case sqlite
    case postgres
}

private enum SingleStatementExecutionPath: Sendable, CaseIterable, CustomStringConvertible {
    case database
    case transaction

    var description: String {
        switch self {
        case .database: "database.execute"
        case .transaction: "transaction.execute"
        }
    }
}

private func singleStatementPostgresConfiguration() -> ConnectionConfiguration {
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
