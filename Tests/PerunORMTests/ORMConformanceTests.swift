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

@Test
func sqlitePassesSharedORMInsertConformance() async throws {
    try await runSharedORMInsertConformance(
        database: SQLiteDatabase(configuration: .memory(), maxConnections: 1)
    )
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresPassesSharedORMInsertConformance() async throws {
    try await runSharedORMInsertConformance(
        database: PostgresDatabase(
            configuration: ormPostgresIntegrationConfiguration(),
            maxConnections: 1
        )
    )
}

@Test
func sqlitePassesSharedORMUpdateConformance() async throws {
    try await runSharedORMUpdateConformance(
        database: SQLiteDatabase(configuration: .memory(), maxConnections: 1)
    )
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresPassesSharedORMUpdateConformance() async throws {
    try await runSharedORMUpdateConformance(
        database: PostgresDatabase(
            configuration: ormPostgresIntegrationConfiguration(),
            maxConnections: 1
        )
    )
}

@Test
func sqlitePassesSharedORMDeleteConformance() async throws {
    try await runSharedORMDeleteConformance(
        database: SQLiteDatabase(configuration: .memory(), maxConnections: 1)
    )
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresPassesSharedORMDeleteConformance() async throws {
    try await runSharedORMDeleteConformance(
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

private func runSharedORMInsertConformance(database: any Database) async throws {
    let dialect = database.dialect
    let renderer = SQLRenderer(dialect: dialect)
    let tableName = ORMInsertRecord.tableName
    let table = dialect.quoteIdentifier(tableName)
    let dropSQL = "DROP TABLE IF EXISTS \(table)"

    do {
        _ = try await database.execute(dropSQL, [])

        let schema = try EntitySchema(ORMInsertRecord.self)
        let createTable = try renderer.render(schema.createTableStatement)
        _ = try await database.execute(createTable.sql, createTable.parameters)

        let session = Session(database: database)
        let inserted = try await session.withUnitOfWork { unitOfWork in
            let inserted = try await unitOfWork.insert(
                ORMInsertRecord(
                    id: 0,
                    name: "committed",
                    nickname: nil,
                    isActive: true
                )
            )
            let found = try await unitOfWork.find(ORMInsertRecord.self, inserted.id)
            #expect(found == inserted)
            return inserted
        }
        #expect(inserted.id > 0)

        let committedSnapshot = try await session.find(ORMInsertRecord.self, inserted.id)
        #expect(committedSnapshot == inserted)
        let freshSession = Session(database: database)
        let stored = try await freshSession.find(ORMInsertRecord.self, inserted.id)
        #expect(stored == inserted)

        let rawDeletedID = try await session.withUnitOfWork { unitOfWork in
            let rawDeleted = try await unitOfWork.insert(
                ORMInsertRecord(
                    id: 0,
                    name: "raw-deleted",
                    nickname: nil,
                    isActive: false
                )
            )
            let delete = try renderer.render(
                SQLDelete(
                    table: tableName,
                    predicate: .comparison(
                        column: "id",
                        op: .eq,
                        value: .int(rawDeleted.id)
                    )
                )
            )
            _ = try await unitOfWork.execute(delete.sql, delete.parameters)
            return rawDeleted.id
        }
        let missingAfterRawDelete = try await session.find(ORMInsertRecord.self, rawDeletedID)
        #expect(missingAfterRawDelete == nil)

        do {
            let _: Void = try await session.withUnitOfWork { unitOfWork in
                do {
                    _ = try await unitOfWork.execute("/* boundary */ ROLLBACK")
                    Issue.record("unit of work accepted transaction control")
                } catch let error as SessionError {
                    #expect(
                        error == .transactionControlNotAllowed(command: "ROLLBACK")
                    )
                }
            }
            Issue.record("unit of work committed after rejected transaction control")
        } catch let error as SessionError {
            #expect(error == .unitOfWorkRollbackOnly)
        }

        let rolledBackID = ORMGeneratedIDBox()
        do {
            let _: Void = try await session.withUnitOfWork { unitOfWork in
                let rolledBack = try await unitOfWork.insert(
                    ORMInsertRecord(
                        id: 0,
                        name: "rolled-back",
                        nickname: "temporary",
                        isActive: false
                    )
                )
                await rolledBackID.store(rolledBack.id)
                throw ORMInsertConformanceError.rollback
            }
            Issue.record("failing ORM unit of work unexpectedly committed")
        } catch let error as ORMInsertConformanceError {
            #expect(error == .rollback)
        }

        let generatedID = try #require(await rolledBackID.value)
        let missingAfterRollback = try await session.find(ORMInsertRecord.self, generatedID)
        #expect(missingAfterRollback == nil)

        _ = try await database.execute(dropSQL, [])
    } catch {
        _ = try? await database.execute(dropSQL, [])
        await database.shutdown()
        throw error
    }

    await database.shutdown()
}

private func runSharedORMUpdateConformance(database: any Database) async throws {
    let dialect = database.dialect
    let renderer = SQLRenderer(dialect: dialect)
    let tableName = ORMUpdateRecord.tableName
    let table = dialect.quoteIdentifier(tableName)
    let dropSQL = "DROP TABLE IF EXISTS \(table)"

    do {
        _ = try await database.execute(dropSQL, [])

        let schema = try EntitySchema(ORMUpdateRecord.self)
        let createTable = try renderer.render(schema.createTableStatement)
        _ = try await database.execute(createTable.sql, createTable.parameters)

        let before = ORMUpdateRecord(
            id: 42,
            name: "before",
            nickname: nil,
            isActive: true
        )
        let insert = try renderer.render(
            SQLInsert(
                table: tableName,
                values: [
                    SQLColumnValue(column: "id", value: .int(before.id)),
                    SQLColumnValue(column: "name", value: .text(before.name)),
                    SQLColumnValue(column: "nickname", value: .null),
                    SQLColumnValue(column: "is_active", value: .bool(before.isActive)),
                ]
            )
        )
        let insertResult = try await database.execute(insert.sql, insert.parameters)
        #expect(insertResult.rowsAffected == 1)

        let session = Session(database: database)
        let managedBefore = try #require(
            await session.find(ORMUpdateRecord.self, before.id)
        )
        #expect(managedBefore == before)

        let committed = ORMUpdateRecord(
            id: before.id,
            name: "committed",
            nickname: "Perun",
            isActive: false
        )
        let updated = try await session.withUnitOfWork { unitOfWork in
            let updated = try await unitOfWork.update(committed, from: managedBefore)
            #expect(updated == committed)
            #expect(try await unitOfWork.find(ORMUpdateRecord.self, before.id) == committed)
            #expect(try await unitOfWork.update(committed, from: updated) == committed)
            return updated
        }
        #expect(updated == committed)
        #expect(try await session.find(ORMUpdateRecord.self, before.id) == committed)

        do {
            let _: Void = try await session.withUnitOfWork { unitOfWork in
                _ = try await unitOfWork.update(
                    ORMUpdateRecord(
                        id: before.id,
                        name: "rolled-back",
                        nickname: nil,
                        isActive: true
                    ),
                    from: updated
                )
                throw ORMUpdateConformanceError.rollback
            }
            Issue.record("failing update unit of work unexpectedly committed")
        } catch let error as ORMUpdateConformanceError {
            #expect(error == .rollback)
        }

        #expect(try await session.find(ORMUpdateRecord.self, before.id) == committed)
        let freshSession = Session(database: database)
        #expect(try await freshSession.find(ORMUpdateRecord.self, before.id) == committed)

        _ = try await database.execute(dropSQL, [])
    } catch {
        _ = try? await database.execute(dropSQL, [])
        await database.shutdown()
        throw error
    }

    await database.shutdown()
}

private func runSharedORMDeleteConformance(database: any Database) async throws {
    let dialect = database.dialect
    let renderer = SQLRenderer(dialect: dialect)
    let tableName = ORMDeleteRecord.tableName
    let table = dialect.quoteIdentifier(tableName)
    let dropSQL = "DROP TABLE IF EXISTS \(table)"

    do {
        _ = try await database.execute(dropSQL, [])

        let schema = try EntitySchema(ORMDeleteRecord.self)
        let createTable = try renderer.render(schema.createTableStatement)
        _ = try await database.execute(createTable.sql, createTable.parameters)

        let committed = ORMDeleteRecord(
            id: 42,
            name: "committed-delete",
            nickname: nil,
            isActive: true
        )
        let rolledBack = ORMDeleteRecord(
            id: 43,
            name: "rolled-back-delete",
            nickname: "temporary",
            isActive: false
        )

        for record in [committed, rolledBack] {
            let insert = try renderer.render(
                SQLInsert(
                    table: tableName,
                    values: [
                        SQLColumnValue(column: "id", value: .int(record.id)),
                        SQLColumnValue(column: "name", value: .text(record.name)),
                        SQLColumnValue(
                            column: "nickname",
                            value: record.nickname.map(SQLValue.text) ?? .null
                        ),
                        SQLColumnValue(
                            column: "is_active",
                            value: .bool(record.isActive)
                        ),
                    ]
                )
            )
            let result = try await database.execute(insert.sql, insert.parameters)
            #expect(result.rowsAffected == 1)
        }

        let session = Session(database: database)
        let managedCommitted = try #require(
            await session.find(ORMDeleteRecord.self, committed.id)
        )

        try await session.withUnitOfWork { unitOfWork in
            try await unitOfWork.delete(managedCommitted)
            #expect(try await unitOfWork.find(ORMDeleteRecord.self, committed.id) == nil)
        }

        #expect(try await session.find(ORMDeleteRecord.self, committed.id) == nil)
        let freshAfterCommit = Session(database: database)
        #expect(try await freshAfterCommit.find(ORMDeleteRecord.self, committed.id) == nil)

        let managedRolledBack = try #require(
            await session.find(ORMDeleteRecord.self, rolledBack.id)
        )
        do {
            let _: Void = try await session.withUnitOfWork { unitOfWork in
                try await unitOfWork.delete(managedRolledBack)
                #expect(
                    try await unitOfWork.find(ORMDeleteRecord.self, rolledBack.id) == nil
                )
                throw ORMDeleteConformanceError.rollback
            }
            Issue.record("failing delete unit of work unexpectedly committed")
        } catch let error as ORMDeleteConformanceError {
            #expect(error == .rollback)
        }

        #expect(try await session.find(ORMDeleteRecord.self, rolledBack.id) == rolledBack)
        let freshAfterRollback = Session(database: database)
        #expect(
            try await freshAfterRollback.find(ORMDeleteRecord.self, rolledBack.id)
                == rolledBack
        )

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

private struct ORMInsertRecord: Entity, Equatable {
    typealias PK = Int64

    let id: Int64
    let name: String
    let nickname: String?
    let isActive: Bool

    static let tableName = "perun_orm_insert_"
        + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    static var fields: [FieldDescriptor<ORMInsertRecord>] {
        [
            FieldDescriptor(
                \ORMInsertRecord.id,
                column: "id",
                role: .primaryKey(generated: true)
            ),
            FieldDescriptor(\ORMInsertRecord.name, column: "name"),
            FieldDescriptor(\ORMInsertRecord.nickname, column: "nickname"),
            FieldDescriptor(\ORMInsertRecord.isActive, column: "is_active"),
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

private struct ORMUpdateRecord: Entity, Equatable {
    typealias PK = Int64

    let id: Int64
    let name: String
    let nickname: String?
    let isActive: Bool

    static let tableName = "perun_orm_update_"
        + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    static var fields: [FieldDescriptor<ORMUpdateRecord>] {
        [
            FieldDescriptor(
                \ORMUpdateRecord.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\ORMUpdateRecord.name, column: "name"),
            FieldDescriptor(\ORMUpdateRecord.nickname, column: "nickname"),
            FieldDescriptor(\ORMUpdateRecord.isActive, column: "is_active"),
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

private struct ORMDeleteRecord: Entity, Equatable {
    typealias PK = Int64

    let id: Int64
    let name: String
    let nickname: String?
    let isActive: Bool

    static let tableName = "perun_orm_delete_"
        + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    static var fields: [FieldDescriptor<ORMDeleteRecord>] {
        [
            FieldDescriptor(
                \ORMDeleteRecord.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\ORMDeleteRecord.name, column: "name"),
            FieldDescriptor(\ORMDeleteRecord.nickname, column: "nickname"),
            FieldDescriptor(\ORMDeleteRecord.isActive, column: "is_active"),
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

private actor ORMGeneratedIDBox {
    private(set) var value: Int64?

    func store(_ value: Int64) {
        self.value = value
    }
}

private enum ORMInsertConformanceError: Error, Sendable, Equatable {
    case rollback
}

private enum ORMUpdateConformanceError: Error, Sendable, Equatable {
    case rollback
}

private enum ORMDeleteConformanceError: Error, Sendable, Equatable {
    case rollback
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
