import Foundation
import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
@testable import PerunMigrations
import PerunPGSQL
import PerunSQLite
import Testing

@Test
func sqliteMigratorMigrateIntegration() async throws {
    try await runMigratorMigrateIntegration(
        database: SQLiteDatabase(
            configuration: .memory(),
            maxConnections: 1
        )
    )
}

@Test
func sqliteMigratorRejectsBOMPrefixedCommitWithoutCommittingBodyEffects() async throws {
    let database = SQLiteDatabase(
        configuration: .memory(),
        maxConnections: 1
    )
    let probeTable = "perun_bom_commit_probe"

    do {
        try await migrateIntegrationCreateProbeTable(probeTable, in: database)
        let migration = Migration(id: "001_bom_commit") { context in
            let statement = try context.renderer.render(
                SQLInsert(
                    table: probeTable,
                    values: [
                        SQLColumnValue(column: "position", value: .int(1)),
                        SQLColumnValue(column: "marker", value: .text("body-effect")),
                    ]
                )
            )
            _ = try await context.execute(statement.sql, statement.parameters)
            _ = try await context.execute("\u{FEFF}COMMIT", [])
        }
        let migrator = try Migrator(
            database: database,
            migrations: [migration],
            trackingTableName: "perun_bom_commit_tracking"
        )

        do {
            _ = try await migrator.migrate()
            Issue.record("BOM-prefixed COMMIT unexpectedly escaped the migration boundary")
        } catch let error as MigrationExecutionError {
            #expect(error == .transactionControlNotAllowed(command: "COMMIT"))
        } catch {
            Issue.record("BOM-prefixed COMMIT returned an unexpected error: \(error)")
        }

        #expect(try await migrateIntegrationProbeRows(in: probeTable, database: database).isEmpty)
    } catch {
        await database.shutdown()
        throw error
    }

    await database.shutdown()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresMigratorMigrateIntegration() async throws {
    try await runMigratorMigrateIntegration(
        database: PostgresDatabase(
            configuration: migrateIntegrationPostgresConfiguration(),
            maxConnections: 1
        )
    )
}

private func runMigratorMigrateIntegration(
    database: any ExclusiveTransactionDatabase
) async throws {
    let tables = MigrateIntegrationTables()

    do {
        try await migrateIntegrationDropTables(tables.all, from: database)
        try await migrateIntegrationCreateProbeTable(tables.successProbe, in: database)
        try await assertFreshNoOpAndAppend(
            database: database,
            trackingTable: tables.successTracking,
            probeTable: tables.successProbe
        )

        try await migrateIntegrationCreateProbeTable(tables.rollbackProbe, in: database)
        try await assertWholeBatchRollback(
            database: database,
            trackingTable: tables.rollbackTracking,
            probeTable: tables.rollbackProbe
        )
        try await migrateIntegrationDropTables(tables.all, from: database)
    } catch {
        await migrateIntegrationBestEffortDropTables(tables.all, from: database)
        await database.shutdown()
        throw error
    }

    await database.shutdown()
}

private func assertFreshNoOpAndAppend(
    database: any ExclusiveTransactionDatabase,
    trackingTable: String,
    probeTable: String
) async throws {
    let first = migrateIntegrationReference(1, "001_create_users", 1)
    let second = migrateIntegrationReference(2, "002_backfill_users", 3)
    let third = migrateIntegrationReference(3, "003_index_users", 2)

    let freshEvents = MigrateIntegrationBodyEvents()
    let freshMigrator = try Migrator(
        database: database,
        migrations: [
            migrateIntegrationProbeMigration(
                reference: first,
                marker: "A",
                probePosition: 1,
                probeTable: probeTable,
                events: freshEvents
            ),
            migrateIntegrationProbeMigration(
                reference: second,
                marker: "B",
                probePosition: 2,
                probeTable: probeTable,
                events: freshEvents
            ),
        ],
        trackingTableName: trackingTable
    )

    let freshReport = try await freshMigrator.migrate()

    #expect(freshReport == MigrationReport(applied: [first, second]))
    #expect(
        await freshEvents.snapshot() == [
            "A:start",
            "A:end",
            "B:start",
            "B:end",
        ]
    )
    #expect(
        try await migrateIntegrationProbeRows(in: probeTable, database: database) == [
            MigrateIntegrationProbeRow(position: 1, marker: "A"),
            MigrateIntegrationProbeRow(position: 2, marker: "B"),
        ]
    )
    #expect(
        try await freshMigrator.status()
            == MigrationStatus(applied: [first, second], pending: [])
    )

    let noOpEvents = MigrateIntegrationBodyEvents()
    let noOpMigrator = try Migrator(
        database: database,
        migrations: [
            migrateIntegrationPoisonMigration(reference: first, events: noOpEvents),
            migrateIntegrationPoisonMigration(reference: second, events: noOpEvents),
        ],
        trackingTableName: trackingTable
    )

    let noOpReport = try await noOpMigrator.migrate()

    #expect(noOpReport == MigrationReport(applied: []))
    #expect(await noOpEvents.snapshot().isEmpty)
    #expect(
        try await migrateIntegrationTrackingRowCount(
            in: trackingTable,
            database: database
        ) == 2
    )

    let appendEvents = MigrateIntegrationBodyEvents()
    let appendMigrator = try Migrator(
        database: database,
        migrations: [
            migrateIntegrationPoisonMigration(reference: first, events: appendEvents),
            migrateIntegrationPoisonMigration(reference: second, events: appendEvents),
            migrateIntegrationProbeMigration(
                reference: third,
                marker: "C",
                probePosition: 3,
                probeTable: probeTable,
                events: appendEvents
            ),
        ],
        trackingTableName: trackingTable
    )

    let appendReport = try await appendMigrator.migrate()

    #expect(appendReport == MigrationReport(applied: [third]))
    #expect(await appendEvents.snapshot() == ["C:start", "C:end"])
    #expect(
        try await appendMigrator.status()
            == MigrationStatus(applied: [first, second, third], pending: [])
    )
    #expect(
        try await migrateIntegrationProbeRows(in: probeTable, database: database) == [
            MigrateIntegrationProbeRow(position: 1, marker: "A"),
            MigrateIntegrationProbeRow(position: 2, marker: "B"),
            MigrateIntegrationProbeRow(position: 3, marker: "C"),
        ]
    )
}

private func assertWholeBatchRollback(
    database: any ExclusiveTransactionDatabase,
    trackingTable: String,
    probeTable: String
) async throws {
    let first = migrateIntegrationReference(1, "001_rollback_a", 1)
    let second = migrateIntegrationReference(2, "002_rollback_b", 1)
    let events = MigrateIntegrationBodyEvents()
    let migrator = try Migrator(
        database: database,
        migrations: [
            migrateIntegrationProbeMigration(
                reference: first,
                marker: "A",
                probePosition: 1,
                probeTable: probeTable,
                events: events
            ),
            migrateIntegrationProbeMigration(
                reference: second,
                marker: "B",
                probePosition: 2,
                probeTable: probeTable,
                events: events,
                failureAfterInsert: .rollbackBodyFailed
            ),
        ],
        trackingTableName: trackingTable
    )

    // Commit both tables before the failing migration transaction. This makes the zero row counts
    // below prove data/tracking rollback rather than merely observe a rolled-back CREATE TABLE.
    let initialStatus = try await migrator.status()
    #expect(initialStatus == MigrationStatus(applied: [], pending: [first, second]))
    #expect(
        try await migrateIntegrationTrackingRowCount(
            in: trackingTable,
            database: database
        ) == 0
    )
    #expect(try await migrateIntegrationProbeRows(in: probeTable, database: database).isEmpty)

    do {
        _ = try await migrator.migrate()
        Issue.record("failing migration batch unexpectedly committed")
    } catch let error as MigrateIntegrationError {
        #expect(error == .rollbackBodyFailed)
    } catch {
        Issue.record("failing migration batch wrapped the original body error: \(error)")
    }

    #expect(
        await events.snapshot() == [
            "A:start",
            "A:end",
            "B:start",
            "B:end",
        ]
    )
    #expect(try await migrateIntegrationProbeRows(in: probeTable, database: database).isEmpty)
    #expect(
        try await migrateIntegrationTrackingRowCount(
            in: trackingTable,
            database: database
        ) == 0
    )

    let statusEvents = MigrateIntegrationBodyEvents()
    let statusMigrator = try Migrator(
        database: database,
        migrations: [
            migrateIntegrationPoisonMigration(reference: first, events: statusEvents),
            migrateIntegrationPoisonMigration(reference: second, events: statusEvents),
        ],
        trackingTableName: trackingTable
    )
    #expect(
        try await statusMigrator.status()
            == MigrationStatus(applied: [], pending: [first, second])
    )
    #expect(await statusEvents.snapshot().isEmpty)
}

private func migrateIntegrationProbeMigration(
    reference: MigrationReference,
    marker: String,
    probePosition: Int64,
    probeTable: String,
    events: MigrateIntegrationBodyEvents,
    failureAfterInsert: MigrateIntegrationError? = nil
) -> Migration {
    Migration(id: reference.id, revision: reference.revision) { context in
        await events.append("\(marker):start")
        let statement = try context.renderer.render(
            SQLInsert(
                table: probeTable,
                values: [
                    SQLColumnValue(column: "position", value: .int(probePosition)),
                    SQLColumnValue(column: "marker", value: .text(marker)),
                ]
            )
        )
        _ = try await context.execute(statement.sql, statement.parameters)
        await events.append("\(marker):end")
        if let failureAfterInsert {
            throw failureAfterInsert
        }
    }
}

private func migrateIntegrationPoisonMigration(
    reference: MigrationReference,
    events: MigrateIntegrationBodyEvents
) -> Migration {
    Migration(id: reference.id, revision: reference.revision) { _ in
        await events.append("\(reference.id):poison")
        throw MigrateIntegrationError.poisonBodyRan(reference.id)
    }
}

private func migrateIntegrationReference(
    _ position: Int64,
    _ id: String,
    _ revision: Int64
) -> MigrationReference {
    MigrationReference(position: position, id: id, revision: revision)
}

private func migrateIntegrationCreateProbeTable(
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

private func migrateIntegrationProbeRows(
    in tableName: String,
    database: any Database
) async throws -> [MigrateIntegrationProbeRow] {
    let statement = try SQLRenderer(dialect: database.dialect).render(
        SQLSelect(
            table: tableName,
            columns: ["position", "marker"],
            orderings: [SQLOrdering(column: "position")]
        )
    )
    let result = try await database.execute(statement.sql, statement.parameters)
    return try result.rows.map { row in
        MigrateIntegrationProbeRow(
            position: try row.decode("position", as: Int64.self),
            marker: try row.decode("marker", as: String.self)
        )
    }
}

private func migrateIntegrationTrackingRowCount(
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

private func migrateIntegrationDropTables(
    _ tableNames: [String],
    from database: any Database
) async throws {
    for tableName in tableNames {
        let quotedTable = database.dialect.quoteIdentifier(tableName)
        _ = try await database.execute("DROP TABLE IF EXISTS \(quotedTable)", [])
    }
}

private func migrateIntegrationBestEffortDropTables(
    _ tableNames: [String],
    from database: any Database
) async {
    for tableName in tableNames {
        let quotedTable = database.dialect.quoteIdentifier(tableName)
        _ = try? await database.execute("DROP TABLE IF EXISTS \(quotedTable)", [])
    }
}

private struct MigrateIntegrationTables {
    let successTracking: String
    let successProbe: String
    let rollbackTracking: String
    let rollbackProbe: String

    init() {
        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        successTracking = "perun_migrate_ok_tracking_\(suffix)"
        successProbe = "perun_migrate_ok_probe_\(suffix)"
        rollbackTracking = "perun_migrate_rb_tracking_\(suffix)"
        rollbackProbe = "perun_migrate_rb_probe_\(suffix)"

        precondition(
            all.allSatisfy { $0.utf8.count <= 63 },
            "integration table names must remain portable"
        )
    }

    var all: [String] {
        [successProbe, successTracking, rollbackProbe, rollbackTracking]
    }
}

private struct MigrateIntegrationProbeRow: Sendable, Equatable {
    let position: Int64
    let marker: String
}

private actor MigrateIntegrationBodyEvents {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private enum MigrateIntegrationError: Error, Sendable, Equatable {
    case rollbackBodyFailed
    case poisonBodyRan(String)
}

private func migrateIntegrationPostgresConfiguration() -> ConnectionConfiguration {
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
