import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
@testable import PerunORM
import Testing

@Test
func predicateBuilderResolvesEveryTypedCombinatorToDBALCore() throws {
    let noNickname: String? = nil
    let nicknames: [String?] = ["active", nil, "pending"]

    #expect(
        try Predicate<QueryRecord>.eq(\QueryRecord.id, 7).core
            == .comparison(column: "id", op: .eq, value: .int(7))
    )
    #expect(
        try Predicate<QueryRecord>.eq(\QueryRecord.nickname, noNickname).core
            == .comparison(column: "nickname", op: .eq, value: .null)
    )
    #expect(
        try Predicate<QueryRecord>.neq(\QueryRecord.nickname, noNickname).core
            == .comparison(column: "nickname", op: .neq, value: .null)
    )
    #expect(
        try Predicate<QueryRecord>.lt(\QueryRecord.score, 1.5).core
            == .comparison(column: "score", op: .lt, value: .double(1.5))
    )
    #expect(
        try Predicate<QueryRecord>.lte(\QueryRecord.id, 10).core
            == .comparison(column: "id", op: .lte, value: .int(10))
    )
    #expect(
        try Predicate<QueryRecord>.gt(\QueryRecord.id, 3).core
            == .comparison(column: "id", op: .gt, value: .int(3))
    )
    #expect(
        try Predicate<QueryRecord>.gte(\QueryRecord.id, 4).core
            == .comparison(column: "id", op: .gte, value: .int(4))
    )
    #expect(
        try Predicate<QueryRecord>.like(\QueryRecord.name, "%Perun%").core
            == .comparison(column: "name", op: .like, value: .text("%Perun%"))
    )
    #expect(
        try Predicate<QueryRecord>.isNull(\QueryRecord.nickname).core
            == .null(column: "nickname", negated: false)
    )
    #expect(
        try Predicate<QueryRecord>.in(\QueryRecord.nickname, nicknames).core
            == .inList(
                column: "nickname",
                values: [.text("active"), .null, .text("pending")]
            )
    )

    let first = try Predicate<QueryRecord>.eq(\QueryRecord.isActive, true)
    let second = try Predicate<QueryRecord>.gte(\QueryRecord.id, 1)
    let third = try Predicate<QueryRecord>.like(\QueryRecord.name, "%bot%")
    #expect(
        first.and(second).and(third).core == .and([
            first.core,
            second.core,
            third.core,
        ])
    )
    #expect(
        first.or(second).or(third).core == .or([
            first.core,
            second.core,
            third.core,
        ])
    )
    #expect(third.not().core == .not(third.core))
}

@Test
func queryBuilderPreservesProjectionAndFluentCallOrder() throws {
    let active = try Predicate<QueryRecord>.eq(\QueryRecord.isActive, true)
    let minimumID = try Predicate<QueryRecord>.gte(\QueryRecord.id, 18)
    let base = try Query(QueryRecord.self)
    let filtered = base.where(active).where(minimumID)
    let ordered = try filtered
        .order(by: \QueryRecord.name)
        .order(by: \QueryRecord.id, desc: true)
    let query = ordered.limit(25, offset: 50)

    #expect(
        query.statement == SQLSelect(
            table: "query\"records",
            columns: ["id", "name", "nickname", "score", "is_active"],
            predicate: .and([active.core, minimumID.core]),
            orderings: [
                SQLOrdering(column: "name"),
                SQLOrdering(column: "id", direction: .descending),
            ],
            limit: 25,
            offset: 50
        )
    )
    #expect(base.statement.predicate == nil)
    #expect(base.statement.orderings.isEmpty)
    #expect(ordered.limit(5).statement.offset == nil)
    #expect(ordered.limit(5, offset: 0).statement.offset == nil)
    requireSendable(active)
    requireSendable(query)
}

@Test
func typedQueryRendersIdenticallyThroughPostgresAndSQLiteGrammars() throws {
    let nicknames: [String?] = ["active", nil, "pending"]
    let minimumID = try Predicate<QueryRecord>.gte(\QueryRecord.id, 18)
    let allowedNicknames = try Predicate<QueryRecord>.in(
        \QueryRecord.nickname,
        nicknames
    )
    let rejectedName = try Predicate<QueryRecord>
        .like(\QueryRecord.name, "%bot%")
        .not()
    let predicate = minimumID.and(allowedNicknames).and(rejectedName)
    let query = try Query(QueryRecord.self)
        .where(predicate)
        .order(by: \QueryRecord.name)
        .order(by: \QueryRecord.id, desc: true)
        .limit(25, offset: 50)

    let postgres = try SQLRenderer(dialect: PostgresDialect()).render(query.statement)
    #expect(
        postgres.sql == """
        SELECT "id", "name", "nickname", "score", "is_active" FROM "query""records" WHERE ("id" >= $1 AND ("nickname" IN ($2, $3) OR "nickname" IS NULL) AND (NOT ("name" LIKE $4))) ORDER BY "name" ASC, "id" DESC LIMIT $5 OFFSET $6
        """
    )
    #expect(
        postgres.parameters == [
            .int(18),
            .text("active"),
            .text("pending"),
            .text("%bot%"),
            .int(25),
            .int(50),
        ]
    )

    let sqlite = try SQLRenderer(dialect: SQLiteDialect()).render(query.statement)
    #expect(
        sqlite.sql == """
        SELECT "id", "name", "nickname", "score", "is_active" FROM "query""records" WHERE ("id" >= ? AND ("nickname" IN (?, ?) OR "nickname" IS NULL) AND (NOT ("name" LIKE ?))) ORDER BY "name" ASC, "id" DESC LIMIT ? OFFSET ?
        """
    )
    #expect(sqlite.parameters == postgres.parameters)
}

@Test
func queryBuilderRejectsUnmappedKeyPathsAndInvalidEntityMetadata() throws {
    let expected = ORMQueryError.unmappedField(
        entity: String(reflecting: QueryRecord.self)
    )

    #expect(throws: expected) {
        try Predicate<QueryRecord>.eq(\QueryRecord.unmapped, "value")
    }

    let query = try Query(QueryRecord.self)
    #expect(throws: expected) {
        try query.order(by: \QueryRecord.unmapped)
    }

    #expect(throws: EntitySchemaError.duplicateColumn("duplicate")) {
        try Query(InvalidQueryRecord.self)
    }
    #expect(throws: EntitySchemaError.duplicateColumn("duplicate")) {
        try Predicate<InvalidQueryRecord>.eq(\InvalidQueryRecord.id, 1)
    }
}

@Test
func queryBuilderLeavesPaginationValidationToTheDialectRenderer() throws {
    let renderer = SQLRenderer(dialect: SQLiteDialect())
    let query = try Query(QueryRecord.self).limit(-1, offset: -2)

    #expect(throws: SQLRenderError.negativeLimit(-1)) {
        try renderer.render(query.statement)
    }
}

@Test
func queryDerivesFirstAndCountExecutionShapesWithoutChangingTheBaseQuery() throws {
    let active = try Predicate<QueryRecord>.eq(\QueryRecord.isActive, true)
    let query = try Query(QueryRecord.self)
        .where(active)
        .order(by: \QueryRecord.id, desc: true)
        .limit(25, offset: 50)

    #expect(
        query.firstQuery.statement == SQLSelect(
            table: "query\"records",
            columns: ["id", "name", "nickname", "score", "is_active"],
            predicate: active.core,
            orderings: [SQLOrdering(column: "id", direction: .descending)],
            limit: 1,
            offset: 50
        )
    )
    #expect(
        query.countStatement == SQLCount(
            table: "query\"records",
            predicate: active.core
        )
    )
    #expect(query.statement.limit == 25)
    #expect(query.limit(0, offset: 2).firstQuery.statement.limit == 0)
    #expect(query.limit(-1).firstQuery.statement.limit == -1)
}

private func requireSendable<Value: Sendable>(_ value: Value) {}

private struct QueryRecord: Entity {
    typealias PK = Int64

    let id: Int64
    let name: String
    let nickname: String?
    let score: Double
    let isActive: Bool

    var unmapped: String { name.uppercased() }

    static let tableName = "query\"records"
    static var fields: [FieldDescriptor<QueryRecord>] {
        [
            FieldDescriptor(
                \QueryRecord.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\QueryRecord.name, column: "name"),
            FieldDescriptor(\QueryRecord.nickname, column: "nickname"),
            FieldDescriptor(\QueryRecord.score, column: "score"),
            FieldDescriptor(\QueryRecord.isActive, column: "is_active"),
        ]
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
        name = try row.decode("name", as: String.self)
        nickname = try row.decode("nickname", as: String?.self)
        score = try row.decode("score", as: Double.self)
        isActive = try row.decode("is_active", as: Bool.self)
    }
}

private struct InvalidQueryRecord: Entity {
    typealias PK = Int64

    let id: Int64
    let name: String

    static let tableName = "invalid_query_records"
    static var fields: [FieldDescriptor<InvalidQueryRecord>] {
        [
            FieldDescriptor(
                \InvalidQueryRecord.id,
                column: "duplicate",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\InvalidQueryRecord.name, column: "duplicate"),
        ]
    }

    init(row: any Row) throws {
        id = try row.decode("duplicate", as: Int64.self)
        name = try row.decode("duplicate", as: String.self)
    }
}
