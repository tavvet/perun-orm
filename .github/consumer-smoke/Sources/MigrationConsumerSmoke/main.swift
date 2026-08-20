import PerunDBAL
import PerunDBALSQLite
import PerunMigrations

@main
struct MigrationConsumerSmoke {
    static func main() async throws {
        let database = SQLiteDatabase(
            configuration: .memory(),
            maxConnections: 1
        )

        do {
            let migrations = [
                Migration(id: "001_create_consumer_smoke") { context in
                    let statement = try context.renderer.render(
                        SQLCreateTable(
                            table: "consumer_smoke",
                            columns: [
                                SQLColumnDefinition(
                                    name: "id",
                                    type: .int64,
                                    role: .primaryKey(generated: false)
                                ),
                            ]
                        )
                    )
                    _ = try await context.execute(
                        statement.sql,
                        statement.parameters
                    )
                },
            ]
            let migrator = try Migrator(
                database: database,
                migrations: migrations
            )

            let initial = try await migrator.status()
            guard initial.applied.isEmpty, initial.pending.count == 1 else {
                throw ConsumerSmokeError.unexpectedInitialStatus
            }

            let first = try await migrator.migrate()
            guard first.applied.count == 1 else {
                throw ConsumerSmokeError.unexpectedFirstReport
            }

            let restart = try await migrator.migrate()
            guard restart.applied.isEmpty else {
                throw ConsumerSmokeError.unexpectedRestartReport
            }

            let nextMigrations = migrations + [
                Migration(id: "002_insert_consumer_smoke") { context in
                    let statement = try context.renderer.render(
                        SQLInsert(
                            table: "consumer_smoke",
                            values: [
                                SQLColumnValue(column: "id", value: .int(1)),
                            ]
                        )
                    )
                    _ = try await context.execute(
                        statement.sql,
                        statement.parameters
                    )
                },
            ]
            let nextMigrator = try Migrator(
                database: database,
                migrations: nextMigrations
            )
            let append = try await nextMigrator.migrate()
            guard append.applied.count == 1 else {
                throw ConsumerSmokeError.unexpectedAppendReport
            }

            let countStatement = try SQLRenderer(dialect: database.dialect).render(
                SQLCount(table: "consumer_smoke")
            )
            let countResult = try await database.execute(
                countStatement.sql,
                countStatement.parameters
            )
            guard let row = countResult.rows.first,
                  try row.decode(SQLCount.resultColumn, as: Int64.self) == 1 else {
                throw ConsumerSmokeError.unexpectedTableState
            }
        } catch {
            await database.shutdown()
            throw error
        }

        await database.shutdown()
    }
}

private enum ConsumerSmokeError: Error {
    case unexpectedInitialStatus
    case unexpectedFirstReport
    case unexpectedRestartReport
    case unexpectedAppendReport
    case unexpectedTableState
}
