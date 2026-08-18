import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
@testable import PerunORM
import os
import Testing

@Test
func entitySchemaBuildsDirtyUpdateASTAndSkipsANoop() throws {
    let schema = try EntitySchema(UpdateRecord.self)
    let snapshot = UpdateRecord(
        id: 7,
        name: "before",
        nickname: nil,
        isActive: true
    )
    let changed = UpdateRecord(
        id: 7,
        name: "after",
        nickname: "Perun",
        isActive: true
    )

    #expect(
        schema.updateStatement(changed, comparedTo: snapshot, returning: true) == SQLUpdate(
            table: "update\"records",
            assignments: [
                SQLColumnValue(column: "name", value: .text("after")),
                SQLColumnValue(column: "nickname", value: .text("Perun")),
            ],
            predicate: .comparison(column: "id", op: .eq, value: .int(7)),
            returning: ["id", "name", "nickname", "is_active"]
        )
    )
    #expect(schema.updateStatement(snapshot, comparedTo: snapshot, returning: true) == nil)
}

@Test
func entitySchemaRejectsReferenceTypeEntities() {
    #expect(throws: EntitySchemaError.referenceTypeUnsupported) {
        try EntitySchema(ReferenceUpdateRecord.self)
    }
}

@Test
func entitySchemaRejectsReferenceTypedMappedFields() {
    #expect(
        throws: EntitySchemaError.referenceFieldTypeUnsupported(column: "name")
    ) {
        try EntitySchema(ReferenceFieldUpdateRecord.self)
    }
    #expect(
        throws: EntitySchemaError.referenceFieldTypeUnsupported(column: "name")
    ) {
        try EntitySchema(OptionalReferenceFieldUpdateRecord.self)
    }
}

@Test
func unitOfWorkUpdateTreatsUnchangedNaNAsTheSameSnapshotValue() async throws {
    let before = FloatingUpdateRecord(id: 31, name: "before", score: .nan)
    let state = UpdateDatabaseState(
        transactionResults: [ExecResult(rowsAffected: 1)],
        directResults: [ExecResult(rows: [floatingUpdateRow(before)])]
    )
    let session = Session(
        database: UpdateDatabase(state: state, dialect: SQLiteDialect())
    )
    let loaded = try #require(await session.find(FloatingUpdateRecord.self, 31))

    let updated = try await session.withUnitOfWork { unitOfWork in
        try await unitOfWork.update(
            FloatingUpdateRecord(id: 31, name: "after", score: .nan),
            from: loaded
        )
    }

    #expect(updated.name == "after")
    #expect(updated.score.isNaN)
    #expect(await state.calls == [
        UpdateDatabaseCall(
            scope: .direct,
            sql: "SELECT \"id\", \"name\", \"score\" FROM \"floating_update_records\" WHERE \"id\" = ? LIMIT ?",
            parameters: [.int(31), .int(2)]
        ),
        UpdateDatabaseCall(
            scope: .transaction,
            sql: "UPDATE \"floating_update_records\" SET \"name\" = ? WHERE \"id\" = ?",
            parameters: [.text("after"), .int(31)]
        ),
    ])
}

@Test
func unitOfWorkUpdateKeepsAFrozenMappedBaseline() async throws {
    let before = ReferenceBackedComputedUpdateRecord(id: 37, name: "before")
    let state = UpdateDatabaseState(
        transactionResults: [],
        directResults: [ExecResult(rows: [referenceBackedUpdateRow(before)])]
    )
    let session = Session(
        database: UpdateDatabase(state: state, dialect: SQLiteDialect())
    )
    let loaded = try #require(
        await session.find(ReferenceBackedComputedUpdateRecord.self, 37)
    )
    loaded.setName("mutated-through-shared-storage")

    do {
        let _: ReferenceBackedComputedUpdateRecord = try await session.withUnitOfWork {
            unitOfWork in
            try await unitOfWork.update(loaded, from: loaded)
        }
        Issue.record("aliased entity mutation changed the managed snapshot")
    } catch let error as ORMError {
        #expect(
            error == .staleEntitySnapshot(
                table: "reference_backed_update_records",
                primaryKey: .int(37)
            )
        )
    }

    let cachedAgain = try #require(
        await session.find(ReferenceBackedComputedUpdateRecord.self, 37)
    )
    #expect(cachedAgain.name == "before")
    #expect(await state.calls.count == 1)
    #expect(await state.calls.first?.scope == .direct)
    #expect(await state.commits == 0)
}

@Test
func cacheHitsMaterializeDetachedEntitiesFromFrozenValues() async throws {
    let before = ReferenceBackedComputedUpdateRecord(id: 41, name: "before")
    let state = UpdateDatabaseState(
        transactionResults: [ExecResult(rowsAffected: 1)],
        directResults: [ExecResult(rows: [referenceBackedUpdateRow(before)])]
    )
    let session = Session(
        database: UpdateDatabase(state: state, dialect: SQLiteDialect())
    )
    let loaded = try #require(
        await session.find(ReferenceBackedComputedUpdateRecord.self, 41)
    )

    let committed = try await session.withUnitOfWork { unitOfWork in
        let returned = try await unitOfWork.update(
            ReferenceBackedComputedUpdateRecord(id: 41, name: "after"),
            from: loaded
        )
        returned.setName("mutated-return-value")

        let firstHit = try #require(
            await unitOfWork.find(ReferenceBackedComputedUpdateRecord.self, 41)
        )
        #expect(firstHit.name == "after")
        firstHit.setName("mutated-first-cache-hit")

        let secondHit = try #require(
            await unitOfWork.find(ReferenceBackedComputedUpdateRecord.self, 41)
        )
        #expect(secondHit.name == "after")
        return secondHit
    }

    committed.setName("mutated-body-result")
    let firstSessionHit = try #require(
        await session.find(ReferenceBackedComputedUpdateRecord.self, 41)
    )
    #expect(firstSessionHit.name == "after")
    firstSessionHit.setName("mutated-session-cache-hit")
    let secondSessionHit = try #require(
        await session.find(ReferenceBackedComputedUpdateRecord.self, 41)
    )
    #expect(secondSessionHit.name == "after")

    #expect(await state.calls.map(\.scope) == [.direct, .transaction])
    #expect(await state.calls.last?.parameters == [.text("after"), .int(41)])
    #expect(await state.commits == 1)
}

@Test
func unitOfWorkUpdateUsesReturningAndPromotesTheCommittedSnapshot() async throws {
    let before = UpdateRecord(id: 7, name: "before", nickname: nil, isActive: true)
    let returned = UpdateRecord(
        id: 7,
        name: "canonical",
        nickname: "Perun",
        isActive: true
    )
    let state = UpdateDatabaseState(
        transactionResults: [
            ExecResult(rows: [updateRow(returned)], rowsAffected: 1),
        ],
        directResults: [ExecResult(rows: [updateRow(before)])]
    )
    let session = Session(
        database: UpdateDatabase(state: state, dialect: PostgresDialect())
    )
    _ = try #require(await session.find(UpdateRecord.self, 7))

    let updated = try await session.withUnitOfWork { unitOfWork in
        let updated = try await unitOfWork.update(
            UpdateRecord(
                id: 7,
                name: "after",
                nickname: "Perun",
                isActive: true
            ),
            from: before
        )
        #expect(try await unitOfWork.find(UpdateRecord.self, 7) == updated)
        return updated
    }

    #expect(updated == returned)
    #expect(try await session.find(UpdateRecord.self, 7) == returned)
    #expect(await state.commits == 1)
    #expect(await state.calls == [
        UpdateDatabaseCall(
            scope: .direct,
            sql: "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"update\"\"records\" WHERE \"id\" = $1 LIMIT $2",
            parameters: [.int(7), .int(2)]
        ),
        UpdateDatabaseCall(
            scope: .transaction,
            sql: "UPDATE \"update\"\"records\" SET \"name\" = $1, \"nickname\" = $2 WHERE \"id\" = $3 RETURNING \"id\", \"name\", \"nickname\", \"is_active\"",
            parameters: [.text("after"), .text("Perun"), .int(7)]
        ),
    ])
}

@Test
func unitOfWorkUpdateDiffsAgainstTheLatestSQLiteOverlay() async throws {
    let before = UpdateRecord(id: 11, name: "before", nickname: nil, isActive: true)
    let first = UpdateRecord(id: 11, name: "after", nickname: nil, isActive: true)
    let second = UpdateRecord(id: 11, name: "after", nickname: "local", isActive: true)
    let state = UpdateDatabaseState(transactionResults: [
        ExecResult(rows: [updateRow(before)]),
        ExecResult(rowsAffected: 1),
        ExecResult(rowsAffected: nil),
    ])
    let session = Session(
        database: UpdateDatabase(state: state, dialect: SQLiteDialect())
    )

    let updated = try await session.withUnitOfWork { unitOfWork in
        let loaded = try #require(await unitOfWork.find(UpdateRecord.self, 11))
        let firstResult = try await unitOfWork.update(first, from: loaded)
        #expect(firstResult == first)
        let secondResult = try await unitOfWork.update(second, from: firstResult)
        #expect(secondResult == second)
        #expect(try await unitOfWork.find(UpdateRecord.self, 11) == second)
        return second
    }

    #expect(updated == second)
    #expect(try await session.find(UpdateRecord.self, 11) == second)
    #expect(await state.commits == 1)
    #expect(await state.calls == [
        UpdateDatabaseCall(
            scope: .transaction,
            sql: "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"update\"\"records\" WHERE \"id\" = ? LIMIT ?",
            parameters: [.int(11), .int(2)]
        ),
        UpdateDatabaseCall(
            scope: .transaction,
            sql: "UPDATE \"update\"\"records\" SET \"name\" = ? WHERE \"id\" = ?",
            parameters: [.text("after"), .int(11)]
        ),
        UpdateDatabaseCall(
            scope: .transaction,
            sql: "UPDATE \"update\"\"records\" SET \"nickname\" = ? WHERE \"id\" = ?",
            parameters: [.text("local"), .int(11)]
        ),
    ])
}

@Test
func unitOfWorkCanUpdateAnEntityInsertedInTheSameTransaction() async throws {
    let inserted = UpdateRecord(id: 12, name: "inserted", nickname: nil, isActive: true)
    let updated = UpdateRecord(id: 12, name: "updated", nickname: nil, isActive: true)
    let state = UpdateDatabaseState(transactionResults: [
        ExecResult(rowsAffected: 1),
        ExecResult(rowsAffected: 1),
    ])
    let session = Session(
        database: UpdateDatabase(state: state, dialect: SQLiteDialect())
    )

    let result = try await session.withUnitOfWork { unitOfWork in
        let insertedResult = try await unitOfWork.insert(inserted)
        #expect(insertedResult == inserted)
        let updatedResult = try await unitOfWork.update(updated, from: insertedResult)
        #expect(updatedResult == updated)
        let found = try await unitOfWork.find(UpdateRecord.self, 12)
        #expect(found == updated)
        return updatedResult
    }

    #expect(result == updated)
    #expect(try await session.find(UpdateRecord.self, 12) == updated)
    #expect(await state.calls == [
        UpdateDatabaseCall(
            scope: .transaction,
            sql: "INSERT INTO \"update\"\"records\" (\"id\", \"name\", \"nickname\", \"is_active\") VALUES (?, ?, ?, ?)",
            parameters: [.int(12), .text("inserted"), .null, .bool(true)]
        ),
        UpdateDatabaseCall(
            scope: .transaction,
            sql: "UPDATE \"update\"\"records\" SET \"name\" = ? WHERE \"id\" = ?",
            parameters: [.text("updated"), .int(12)]
        ),
    ])
}

@Test
func unitOfWorkUpdateDoesNotExecuteSQLForAnEmptyDiff() async throws {
    let snapshot = UpdateRecord(id: 13, name: "same", nickname: nil, isActive: false)
    let state = UpdateDatabaseState(
        transactionResults: [],
        directResults: [ExecResult(rows: [updateRow(snapshot)])]
    )
    let session = Session(
        database: UpdateDatabase(state: state, dialect: SQLiteDialect())
    )
    _ = try #require(await session.find(UpdateRecord.self, 13))

    let updated = try await session.withUnitOfWork { unitOfWork in
        try await unitOfWork.update(snapshot, from: snapshot)
    }

    #expect(updated == snapshot)
    #expect(try await session.find(UpdateRecord.self, 13) == snapshot)
    #expect(await state.commits == 1)
    #expect(await state.calls.count == 1)
    #expect(await state.calls.first?.scope == .direct)
}

@Test
func unitOfWorkUpdateRejectsADetachedSnapshotBeforeWrite() async throws {
    let snapshot = UpdateRecord(id: 15, name: "detached", nickname: nil, isActive: true)
    let state = UpdateDatabaseState(transactionResults: [])
    let session = Session(
        database: UpdateDatabase(state: state, dialect: SQLiteDialect())
    )

    do {
        let _: UpdateRecord = try await session.withUnitOfWork { unitOfWork in
            try await unitOfWork.update(
                UpdateRecord(id: 15, name: "changed", nickname: nil, isActive: true),
                from: snapshot
            )
        }
        Issue.record("update accepted a detached snapshot")
    } catch let error as ORMError {
        #expect(
            error == .entityNotManaged(
                table: "update\"records",
                primaryKey: .int(15)
            )
        )
    }

    #expect(await state.calls.isEmpty)
    #expect(await state.commits == 0)
}

@Test
func unitOfWorkUpdateRejectsAPrimaryKeyChangeWithoutPoisoningTheUnitOfWork() async throws {
    let before = UpdateRecord(id: 17, name: "before", nickname: nil, isActive: true)
    let other = UpdateRecord(id: 18, name: "other", nickname: nil, isActive: false)
    let state = UpdateDatabaseState(
        transactionResults: [ExecResult(rowsAffected: 1)],
        directResults: [
            ExecResult(rows: [updateRow(before)]),
            ExecResult(rows: [updateRow(other)]),
        ]
    )
    let session = Session(
        database: UpdateDatabase(state: state, dialect: SQLiteDialect())
    )
    _ = try #require(await session.find(UpdateRecord.self, 17))
    _ = try #require(await session.find(UpdateRecord.self, 18))

    let recovered = try await session.withUnitOfWork { unitOfWork in
        do {
            _ = try await unitOfWork.update(
                UpdateRecord(id: 18, name: "moved", nickname: nil, isActive: true),
                from: before
            )
            Issue.record("update accepted an entity whose primary key no longer matched")
        } catch let error as ORMError {
            #expect(
                error == .primaryKeyChanged(
                    table: "update\"records",
                    expected: .int(17),
                    actual: .int(18)
                )
            )
        }

        return try await unitOfWork.update(
            UpdateRecord(id: 17, name: "after", nickname: nil, isActive: true),
            from: before
        )
    }

    #expect(recovered.name == "after")
    #expect(await state.commits == 1)
    #expect(await state.calls.count == 3)
    #expect(await state.calls.map(\.scope) == [.direct, .direct, .transaction])
    #expect(await state.calls.last?.parameters == [.text("after"), .int(17)])
    #expect(try await session.find(UpdateRecord.self, 17) == recovered)
    #expect(try await session.find(UpdateRecord.self, 18) == other)
}

@Test
func unitOfWorkUpdateRejectsAStaleSnapshotWithoutPoisoningTheUnitOfWork() async throws {
    let before = UpdateRecord(id: 18, name: "before", nickname: nil, isActive: true)
    let first = UpdateRecord(id: 18, name: "first", nickname: nil, isActive: true)
    let second = UpdateRecord(id: 18, name: "second", nickname: nil, isActive: true)
    let state = UpdateDatabaseState(
        transactionResults: [
            ExecResult(rowsAffected: 1),
            ExecResult(rowsAffected: 1),
        ],
        directResults: [ExecResult(rows: [updateRow(before)])]
    )
    let session = Session(
        database: UpdateDatabase(state: state, dialect: SQLiteDialect())
    )
    _ = try #require(await session.find(UpdateRecord.self, 18))

    let result = try await session.withUnitOfWork { unitOfWork in
        let firstResult = try await unitOfWork.update(first, from: before)
        do {
            _ = try await unitOfWork.update(second, from: before)
            Issue.record("update accepted a stale base snapshot")
        } catch let error as ORMError {
            #expect(
                error == .staleEntitySnapshot(
                    table: "update\"records",
                    primaryKey: .int(18)
                )
            )
        }
        return try await unitOfWork.update(second, from: firstResult)
    }

    #expect(result == second)
    #expect(await state.commits == 1)
    #expect(await state.calls.map(\.scope) == [.direct, .transaction, .transaction])
    #expect(try await session.find(UpdateRecord.self, 18) == second)
}

@Test
func swallowedMissingRowAfterUpdateForcesRollbackAndEvictsTheBaseSnapshot() async throws {
    let before = UpdateRecord(id: 19, name: "before", nickname: nil, isActive: true)
    let state = UpdateDatabaseState(
        transactionResults: [ExecResult(rowsAffected: 0)],
        directResults: [
            ExecResult(rows: [updateRow(before)]),
            ExecResult(rows: []),
        ]
    )
    let session = Session(
        database: UpdateDatabase(state: state, dialect: SQLiteDialect())
    )
    _ = try #require(await session.find(UpdateRecord.self, 19))

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            do {
                _ = try await unitOfWork.update(
                    UpdateRecord(id: 19, name: "after", nickname: nil, isActive: true),
                    from: before
                )
                Issue.record("update accepted rowsAffected == 0")
            } catch let error as ORMError {
                #expect(
                    error == .entityNotFound(
                        table: "update\"records",
                        primaryKey: .int(19)
                    )
                )
            }
        }
        Issue.record("unit of work committed after a swallowed post-write error")
    } catch let error as SessionError {
        #expect(error == .unitOfWorkRollbackOnly)
    }

    #expect(await state.commits == 0)
    #expect(try await session.find(UpdateRecord.self, 19) == nil)
    #expect(await state.calls.map(\.scope) == [.direct, .transaction, .direct])
}

@Test
func unitOfWorkUpdateRejectsMultipleAffectedAndReturnedRows() async throws {
    let before = UpdateRecord(id: 23, name: "before", nickname: nil, isActive: true)
    let sqliteState = UpdateDatabaseState(
        transactionResults: [ExecResult(rowsAffected: 2)],
        directResults: [ExecResult(rows: [updateRow(before)])]
    )
    let sqliteSession = Session(
        database: UpdateDatabase(state: sqliteState, dialect: SQLiteDialect())
    )
    _ = try #require(await sqliteSession.find(UpdateRecord.self, 23))

    do {
        let _: UpdateRecord = try await sqliteSession.withUnitOfWork { unitOfWork in
            try await unitOfWork.update(
                UpdateRecord(id: 23, name: "after", nickname: nil, isActive: true),
                from: before
            )
        }
        Issue.record("update accepted multiple affected rows")
    } catch let error as ORMError {
        #expect(
            error == .unexpectedUpdateAffectedRowCount(
                table: "update\"records",
                primaryKey: .int(23),
                actual: 2
            )
        )
    }
    #expect(await sqliteState.commits == 0)

    let postgresState = UpdateDatabaseState(
        transactionResults: [ExecResult(rows: [], rowsAffected: 1)],
        directResults: [ExecResult(rows: [updateRow(before)])]
    )
    let postgresSession = Session(
        database: UpdateDatabase(state: postgresState, dialect: PostgresDialect())
    )
    _ = try #require(await postgresSession.find(UpdateRecord.self, 23))

    do {
        let _: UpdateRecord = try await postgresSession.withUnitOfWork { unitOfWork in
            try await unitOfWork.update(
                UpdateRecord(id: 23, name: "after", nickname: nil, isActive: true),
                from: before
            )
        }
        Issue.record("update accepted an empty RETURNING result")
    } catch let error as ORMError {
        #expect(
            error == .unexpectedUpdateResultRowCount(
                table: "update\"records",
                primaryKey: .int(23),
                actual: 0
            )
        )
    }
    #expect(await postgresState.commits == 0)
}

@Test
func unitOfWorkUpdateRejectsAMismatchedReturnedPrimaryKey() async throws {
    let before = UpdateRecord(id: 27, name: "before", nickname: nil, isActive: true)
    let wrongRow = UpdateRecord(id: 28, name: "after", nickname: nil, isActive: true)
    let state = UpdateDatabaseState(
        transactionResults: [
            ExecResult(rows: [updateRow(wrongRow)], rowsAffected: 1),
        ],
        directResults: [ExecResult(rows: [updateRow(before)])]
    )
    let session = Session(
        database: UpdateDatabase(state: state, dialect: PostgresDialect())
    )
    _ = try #require(await session.find(UpdateRecord.self, 27))

    do {
        let _: UpdateRecord = try await session.withUnitOfWork { unitOfWork in
            try await unitOfWork.update(
                UpdateRecord(id: 27, name: "after", nickname: nil, isActive: true),
                from: before
            )
        }
        Issue.record("update accepted a RETURNING row with a different primary key")
    } catch let error as ORMError {
        #expect(
            error == .hydratedPrimaryKeyMismatch(
                table: "update\"records",
                expected: .int(27),
                actual: .int(28)
            )
        )
    }

    #expect(await state.commits == 0)
}

@Test
func commitFailureDoesNotPromoteTheUpdatedSnapshot() async throws {
    let before = UpdateRecord(id: 29, name: "before", nickname: nil, isActive: true)
    let observedAfterFailure = UpdateRecord(
        id: 29,
        name: "database-outcome",
        nickname: nil,
        isActive: true
    )
    let state = UpdateDatabaseState(
        transactionResults: [ExecResult(rowsAffected: 1)],
        directResults: [
            ExecResult(rows: [updateRow(before)]),
            ExecResult(rows: [updateRow(observedAfterFailure)]),
        ],
        failCommit: true
    )
    let session = Session(
        database: UpdateDatabase(state: state, dialect: SQLiteDialect())
    )
    _ = try #require(await session.find(UpdateRecord.self, 29))

    do {
        let _: UpdateRecord = try await session.withUnitOfWork { unitOfWork in
            try await unitOfWork.update(
                UpdateRecord(id: 29, name: "attempted", nickname: nil, isActive: true),
                from: before
            )
        }
        Issue.record("unit of work ignored a commit failure")
    } catch let error as UpdateTestError {
        #expect(error == .commitFailed)
    }

    #expect(await state.commits == 1)
    #expect(try await session.find(UpdateRecord.self, 29) == observedAfterFailure)
    #expect(await state.calls.map(\.scope) == [.direct, .transaction, .direct])
}

private struct UpdateRecord: Entity, Equatable {
    typealias PK = Int64

    let id: Int64
    let name: String
    let nickname: String?
    let isActive: Bool

    static let tableName = "update\"records"
    static var fields: [FieldDescriptor<UpdateRecord>] {
        [
            FieldDescriptor(
                \UpdateRecord.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\UpdateRecord.name, column: "name"),
            FieldDescriptor(\UpdateRecord.nickname, column: "nickname"),
            FieldDescriptor(\UpdateRecord.isActive, column: "is_active"),
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

private final class ReferenceUpdateRecord: Entity, Sendable {
    typealias PK = Int64

    let id: Int64
    let name: String

    static let tableName = "reference_update_records"
    static var fields: [FieldDescriptor<ReferenceUpdateRecord>] {
        [
            FieldDescriptor(
                \ReferenceUpdateRecord.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\ReferenceUpdateRecord.name, column: "name"),
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

private final class ReferenceMappedText: SQLValueConvertible, Sendable {
    static let columnType = ColumnType.text

    let value: String

    init(_ value: String) {
        self.value = value
    }

    var sqlValue: SQLValue { .text(value) }

    init(sqlValue: SQLValue) throws {
        guard case let .text(value) = sqlValue else {
            throw SQLValueConversionError.typeMismatch(expected: .text, actual: sqlValue)
        }
        self.value = value
    }
}

private struct ReferenceFieldUpdateRecord: Entity {
    typealias PK = Int64

    let id: Int64
    let name: ReferenceMappedText

    static let tableName = "reference_field_update_records"
    static var fields: [FieldDescriptor<ReferenceFieldUpdateRecord>] {
        [
            FieldDescriptor(
                \ReferenceFieldUpdateRecord.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\ReferenceFieldUpdateRecord.name, column: "name"),
        ]
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
        name = try row.decode("name", as: ReferenceMappedText.self)
    }
}

private struct OptionalReferenceFieldUpdateRecord: Entity {
    typealias PK = Int64

    let id: Int64
    let name: ReferenceMappedText?

    static let tableName = "optional_reference_field_update_records"
    static var fields: [FieldDescriptor<OptionalReferenceFieldUpdateRecord>] {
        [
            FieldDescriptor(
                \OptionalReferenceFieldUpdateRecord.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\OptionalReferenceFieldUpdateRecord.name, column: "name"),
        ]
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
        name = try row.decode("name", as: ReferenceMappedText?.self)
    }
}

private struct FloatingUpdateRecord: Entity {
    typealias PK = Int64

    let id: Int64
    let name: String
    let score: Double

    static let tableName = "floating_update_records"
    static var fields: [FieldDescriptor<FloatingUpdateRecord>] {
        [
            FieldDescriptor(
                \FloatingUpdateRecord.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\FloatingUpdateRecord.name, column: "name"),
            FieldDescriptor(\FloatingUpdateRecord.score, column: "score"),
        ]
    }

    init(id: Int64, name: String, score: Double) {
        self.id = id
        self.name = name
        self.score = score
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
        name = try row.decode("name", as: String.self)
        score = try row.decode("score", as: Double.self)
    }
}

private final class MutableUpdateName: Sendable {
    private let storage: OSAllocatedUnfairLock<String>

    init(_ value: String) {
        storage = OSAllocatedUnfairLock(initialState: value)
    }

    var value: String {
        storage.withLock { $0 }
    }

    func set(_ value: String) {
        storage.withLock { $0 = value }
    }
}

private struct ReferenceBackedComputedUpdateRecord: Entity {
    typealias PK = Int64

    let id: Int64
    private let nameStorage: MutableUpdateName
    var name: String { nameStorage.value }

    static let tableName = "reference_backed_update_records"
    static var fields: [FieldDescriptor<ReferenceBackedComputedUpdateRecord>] {
        [
            FieldDescriptor(
                \ReferenceBackedComputedUpdateRecord.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\ReferenceBackedComputedUpdateRecord.name, column: "name"),
        ]
    }

    init(id: Int64, name: String) {
        self.id = id
        nameStorage = MutableUpdateName(name)
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
        nameStorage = MutableUpdateName(try row.decode("name", as: String.self))
    }

    func setName(_ value: String) {
        nameStorage.set(value)
    }
}

private func updateRow(_ record: UpdateRecord) -> UpdateRow {
    UpdateRow(values: [
        "id": .int(record.id),
        "name": .text(record.name),
        "nickname": record.nickname.map(SQLValue.text) ?? .null,
        "is_active": .bool(record.isActive),
    ])
}

private func floatingUpdateRow(_ record: FloatingUpdateRecord) -> UpdateRow {
    UpdateRow(values: [
        "id": .int(record.id),
        "name": .text(record.name),
        "score": .double(record.score),
    ])
}

private func referenceBackedUpdateRow(
    _ record: ReferenceBackedComputedUpdateRecord
) -> UpdateRow {
    UpdateRow(values: [
        "id": .int(record.id),
        "name": .text(record.name),
    ])
}

private struct UpdateDatabaseCall: Sendable, Equatable {
    enum Scope: Sendable, Equatable {
        case direct
        case transaction
    }

    let scope: Scope
    let sql: String
    let parameters: [SQLValue]
}

private actor UpdateDatabaseState {
    private var transactionResults: [ExecResult]
    private var directResults: [ExecResult]
    private let failCommit: Bool
    private(set) var calls: [UpdateDatabaseCall] = []
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
        scope: UpdateDatabaseCall.Scope,
        sql: String,
        parameters: [SQLValue]
    ) throws -> ExecResult {
        calls.append(UpdateDatabaseCall(scope: scope, sql: sql, parameters: parameters))
        switch scope {
        case .direct:
            guard !directResults.isEmpty else {
                throw UpdateTestError.unexpectedExecution
            }
            return directResults.removeFirst()
        case .transaction:
            guard !transactionResults.isEmpty else {
                throw UpdateTestError.unexpectedExecution
            }
            return transactionResults.removeFirst()
        }
    }

    func commit() throws {
        commits += 1
        if failCommit {
            throw UpdateTestError.commitFailed
        }
    }
}

private struct UpdateDatabase: Database {
    let state: UpdateDatabaseState
    let configuredDialect: any SQLDialect

    init(state: UpdateDatabaseState, dialect: any SQLDialect) {
        self.state = state
        configuredDialect = dialect
    }

    var dialect: any SQLDialect { configuredDialect }

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
        let result = try await body(UpdateTransaction(state: state))
        try await state.commit()
        return result
    }

    func shutdown() async {}
}

private struct UpdateTransaction: Transaction {
    let state: UpdateDatabaseState

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await state.execute(scope: .transaction, sql: sql, parameters: parameters)
    }
}

private struct UpdateRow: Row {
    let values: [String: SQLValue]

    func decode<T: SQLValueConvertible>(_ column: String, as type: T.Type) throws -> T {
        guard let value = values[column] else {
            throw UpdateTestError.missingColumn(column)
        }
        return try T(sqlValue: value)
    }

    func decodeIfPresent<T: SQLValueConvertible>(
        _ column: String,
        as type: T.Type
    ) throws -> T? {
        guard let value = values[column] else {
            throw UpdateTestError.missingColumn(column)
        }
        guard value != .null else { return nil }
        return try T(sqlValue: value)
    }
}

private enum UpdateTestError: Error, Equatable {
    case commitFailed
    case missingColumn(String)
    case unexpectedExecution
}
