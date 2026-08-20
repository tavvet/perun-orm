import Foundation
import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
@testable import PerunMigrations
import PerunPGSQL
import PerunSQLite
import Testing

@Test
func sqliteMigratorStatusIntegration() async throws {
    try await runMigratorStatusIntegration(
        database: SQLiteDatabase(
            configuration: .memory(),
            maxConnections: 1
        )
    )
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresMigratorStatusIntegration() async throws {
    try await runMigratorStatusIntegration(
        database: PostgresDatabase(
            configuration: migrationsPostgresIntegrationConfiguration(),
            maxConnections: 1
        )
    )
}

private func runMigratorStatusIntegration(
    database: any ExclusiveTransactionDatabase
) async throws {
    let tables = StatusTrackingTables()
    let tableNames = [tables.primary, tables.isolated, tables.invalid]

    do {
        try await dropTrackingTables(tableNames, from: database)
        try await assertMigratorStatusBehavior(
            database: database,
            tables: tables
        )
        try await dropTrackingTables(tableNames, from: database)
    } catch {
        await bestEffortDropTrackingTables(tableNames, from: database)
        await database.shutdown()
        throw error
    }

    await database.shutdown()
}

private func assertMigratorStatusBehavior(
    database: any ExclusiveTransactionDatabase,
    tables: StatusTrackingTables
) async throws {
    let bodyProbe = StatusMigrationBodyProbe()
    let migrations = statusMigrations(bodyProbe: bodyProbe)
    let references = statusMigrationReferences()

    let freshMigrator = try Migrator(
        database: database,
        migrations: migrations,
        trackingTableName: tables.primary
    )
    let freshStatus = try await freshMigrator.status()

    #expect(freshStatus.applied.isEmpty)
    #expect(freshStatus.pending == references)
    #expect(try await trackingRowCount(in: tables.primary, database: database) == 0)
    #expect(await bodyProbe.count == 0)

    let repeatedMigrator = try Migrator(
        database: database,
        migrations: migrations,
        trackingTableName: tables.primary
    )
    let repeatedStatus = try await repeatedMigrator.status()

    #expect(repeatedStatus == freshStatus)
    #expect(try await trackingRowCount(in: tables.primary, database: database) == 0)
    #expect(await bodyProbe.count == 0)

    try await insertTrackingRow(
        into: tables.primary,
        reference: references[1],
        appliedAt: SQLTimestamp(microsecondsSinceUnixEpoch: 1_700_000_000_222_222),
        database: database
    )
    try await insertTrackingRow(
        into: tables.primary,
        reference: references[0],
        appliedAt: SQLTimestamp(microsecondsSinceUnixEpoch: 1_700_000_000_111_111),
        database: database
    )

    let seededMigrator = try Migrator(
        database: database,
        migrations: migrations,
        trackingTableName: tables.primary
    )
    let seededStatus = try await seededMigrator.status()

    #expect(seededStatus.applied == Array(references.prefix(2)))
    #expect(seededStatus.pending == Array(references.dropFirst(2)))
    #expect(try await trackingRowCount(in: tables.primary, database: database) == 2)
    #expect(await bodyProbe.count == 0)

    let isolatedMigrator = try Migrator(
        database: database,
        migrations: migrations,
        trackingTableName: tables.isolated
    )
    let isolatedStatus = try await isolatedMigrator.status()

    #expect(isolatedStatus.applied.isEmpty)
    #expect(isolatedStatus.pending == references)
    #expect(try await trackingRowCount(in: tables.isolated, database: database) == 0)
    #expect(try await trackingRowCount(in: tables.primary, database: database) == 2)
    #expect(await bodyProbe.count == 0)

    let invalidMigrator = try Migrator(
        database: database,
        migrations: migrations,
        trackingTableName: tables.invalid
    )
    let invalidFreshStatus = try await invalidMigrator.status()
    #expect(invalidFreshStatus.applied.isEmpty)
    #expect(invalidFreshStatus.pending == references)

    try await insertTrackingRow(
        into: tables.invalid,
        position: 1,
        id: "",
        revision: 1,
        appliedAt: SQLTimestamp(microsecondsSinceUnixEpoch: 1_700_000_000_333_333),
        database: database
    )

    let expectedError = MigrationHistoryError.malformedRow(
        rowOrdinal: 1,
        column: "id",
        reason: .invalidValue
    )
    do {
        _ = try await invalidMigrator.status()
        Issue.record("status unexpectedly accepted an invalid persisted migration ID")
    } catch let error as MigrationHistoryError {
        #expect(error == expectedError)
    } catch {
        Issue.record("status threw an unexpected error: \(error)")
    }

    #expect(await bodyProbe.count == 0)
}

private func statusMigrations(
    bodyProbe: StatusMigrationBodyProbe
) -> [Migration] {
    [
        Migration(id: "001_create_users") { _ in
            await bodyProbe.recordInvocation()
        },
        Migration(id: "002_backfill_users", revision: 3) { _ in
            await bodyProbe.recordInvocation()
        },
        Migration(id: "003_index_users", revision: 2) { _ in
            await bodyProbe.recordInvocation()
        },
    ]
}

private func statusMigrationReferences() -> [MigrationReference] {
    [
        MigrationReference(position: 1, id: "001_create_users", revision: 1),
        MigrationReference(position: 2, id: "002_backfill_users", revision: 3),
        MigrationReference(position: 3, id: "003_index_users", revision: 2),
    ]
}

private func insertTrackingRow(
    into tableName: String,
    reference: MigrationReference,
    appliedAt: SQLTimestamp,
    database: any Database
) async throws {
    try await insertTrackingRow(
        into: tableName,
        position: reference.position,
        id: reference.id,
        revision: reference.revision,
        appliedAt: appliedAt,
        database: database
    )
}

private func insertTrackingRow(
    into tableName: String,
    position: Int64,
    id: String,
    revision: Int64,
    appliedAt: SQLTimestamp,
    database: any Database
) async throws {
    let statement = try SQLRenderer(dialect: database.dialect).render(
        SQLInsert(
            table: tableName,
            values: [
                SQLColumnValue(column: "position", value: .int(position)),
                SQLColumnValue(column: "id", value: .text(id)),
                SQLColumnValue(column: "revision", value: .int(revision)),
                SQLColumnValue(column: "applied_at", value: .date(appliedAt)),
            ]
        )
    )
    let result = try await database.execute(statement.sql, statement.parameters)
    #expect(result.rowsAffected == 1)
}

private func trackingRowCount(
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

private func dropTrackingTables(
    _ tableNames: [String],
    from database: any Database
) async throws {
    for tableName in tableNames {
        let quotedTable = database.dialect.quoteIdentifier(tableName)
        _ = try await database.execute("DROP TABLE IF EXISTS \(quotedTable)", [])
    }
}

private func bestEffortDropTrackingTables(
    _ tableNames: [String],
    from database: any Database
) async {
    for tableName in tableNames {
        let quotedTable = database.dialect.quoteIdentifier(tableName)
        _ = try? await database.execute("DROP TABLE IF EXISTS \(quotedTable)", [])
    }
}

private struct StatusTrackingTables {
    let primary: String
    let isolated: String
    let invalid: String

    init() {
        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        primary = "perun_status_primary_\(suffix)"
        isolated = "perun_status_isolated_\(suffix)"
        invalid = "perun_status_invalid_\(suffix)"

        precondition(
            [primary, isolated, invalid].allSatisfy { $0.utf8.count <= 63 },
            "integration tracking table names must remain portable"
        )
    }
}

private actor StatusMigrationBodyProbe {
    private(set) var count = 0

    func recordInvocation() {
        count += 1
    }
}

private func migrationsPostgresIntegrationConfiguration() -> ConnectionConfiguration {
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
