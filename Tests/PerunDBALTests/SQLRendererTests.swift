import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
import Testing

@Test
func selectRendererQuotesIdentifiersAndBindsInOneDeterministicPass() throws {
    let select = SQLSelect(
        table: "user\"records",
        columns: ["id", "display\"name"],
        predicate: .and([
            .comparison(column: "age", op: .gte, value: .int(18)),
            .inList(column: "status", values: [.text("active"), .null, .text("pending")]),
            .not(.comparison(column: "display\"name", op: .like, value: .text("%bot%"))),
        ]),
        orderings: [
            SQLOrdering(column: "display\"name"),
            SQLOrdering(column: "id", direction: .descending),
        ],
        limit: 25,
        offset: 50
    )

    let postgres = try SQLRenderer(dialect: PostgresDialect()).render(select)
    #expect(
        postgres.sql == """
        SELECT "id", "display""name" FROM "user""records" WHERE ("age" >= $1 AND ("status" IN ($2, $3) OR "status" IS NULL) AND (NOT ("display""name" LIKE $4))) ORDER BY "display""name" ASC, "id" DESC LIMIT $5 OFFSET $6
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

    let sqlite = try SQLRenderer(dialect: SQLiteDialect()).render(select)
    #expect(
        sqlite.sql == """
        SELECT "id", "display""name" FROM "user""records" WHERE ("age" >= ? AND ("status" IN (?, ?) OR "status" IS NULL) AND (NOT ("display""name" LIKE ?))) ORDER BY "display""name" ASC, "id" DESC LIMIT ? OFFSET ?
        """
    )
    #expect(sqlite.parameters == postgres.parameters)
}

@Test
func selectRendererRewritesNullAndEmptyPredicateCases() throws {
    let select = SQLSelect(
        table: "samples",
        columns: ["id"],
        predicate: .and([
            .comparison(column: "deleted_at", op: .eq, value: .null),
            .comparison(column: "archived_at", op: .neq, value: .null),
            .inList(column: "empty", values: []),
            .inList(column: "nullable", values: [.null]),
            .null(column: "present", negated: true),
            .or([]),
            .and([]),
        ])
    )

    let rendered = try SQLRenderer(dialect: PostgresDialect()).render(select)
    #expect(
        rendered.sql == """
        SELECT "id" FROM "samples" WHERE ("deleted_at" IS NULL AND "archived_at" IS NOT NULL AND 1 = 0 AND "nullable" IS NULL AND "present" IS NOT NULL AND 1 = 0 AND 1 = 1)
        """
    )
    #expect(rendered.parameters.isEmpty)
}

@Test
func selectRendererUsesTheDialectsPaginationGrammarAndBindOrder() throws {
    let select = SQLSelect(
        table: "samples",
        columns: ["id"],
        limit: 25,
        offset: 50
    )

    let rendered = try SQLRenderer(dialect: StandardDialect()).render(select)
    #expect(
        rendered == RenderedSQL(
            sql: "SELECT \"id\" FROM \"samples\" OFFSET :1 ROWS FETCH FIRST :2 ROWS ONLY",
            parameters: [.int(50), .int(25)]
        )
    )
}

@Test
func selectRendererPlacesPrefixPaginationBeforeProjectionAndBindsLexically() throws {
    let select = SQLSelect(
        table: "samples",
        columns: ["id"],
        predicate: .comparison(column: "status", op: .eq, value: .text("active")),
        limit: 25
    )

    let rendered = try SQLRenderer(dialect: SQLServerLikeDialect()).render(select)
    #expect(
        rendered == RenderedSQL(
            sql: "SELECT TOP (:1) \"id\" FROM \"samples\" WHERE \"status\" = :2",
            parameters: [.int(25), .text("active")]
        )
    )
}

@Test
func selectRendererLetsTheDialectValidateSuffixPaginationContext() throws {
    let renderer = SQLRenderer(dialect: SQLServerLikeDialect())

    #expect(throws: SQLServerLikeError.offsetRequiresOrdering) {
        try renderer.render(
            SQLSelect(table: "samples", columns: ["id"], limit: 25, offset: 50)
        )
    }

    let rendered = try renderer.render(
        SQLSelect(
            table: "samples",
            columns: ["id"],
            predicate: .comparison(column: "status", op: .eq, value: .text("active")),
            orderings: [SQLOrdering(column: "id")],
            limit: 25,
            offset: 50
        )
    )
    #expect(
        rendered == RenderedSQL(
            sql: "SELECT \"id\" FROM \"samples\" WHERE \"status\" = :1 ORDER BY \"id\" ASC OFFSET :2 ROWS FETCH NEXT :3 ROWS ONLY",
            parameters: [.text("active"), .int(50), .int(25)]
        )
    )
}

@Test
func selectRendererRejectsNullForOrderedComparisons() {
    let renderer = SQLRenderer(dialect: PostgresDialect())
    let invalidOperators: [ComparisonOp] = [.lt, .lte, .gt, .gte, .like]

    for op in invalidOperators {
        let select = SQLSelect(
            table: "samples",
            columns: ["id"],
            predicate: .comparison(column: "value", op: op, value: .null)
        )
        #expect(throws: SQLRenderError.nullComparison(op)) {
            try renderer.render(select)
        }
    }
}

@Test
func selectRendererRejectsStructurallyInvalidStatements() {
    let renderer = SQLRenderer(dialect: SQLiteDialect())

    #expect(throws: SQLRenderError.emptyTable) {
        try renderer.render(SQLSelect(table: "", columns: ["id"]))
    }
    #expect(throws: SQLRenderError.noSelectedColumns) {
        try renderer.render(SQLSelect(table: "samples", columns: []))
    }
    #expect(throws: SQLRenderError.emptyColumn) {
        try renderer.render(SQLSelect(table: "samples", columns: [""]))
    }
    #expect(throws: SQLRenderError.emptyColumn) {
        try renderer.render(
            SQLSelect(
                table: "samples",
                columns: ["id"],
                predicate: .null(column: "", negated: false)
            )
        )
    }
    #expect(throws: SQLRenderError.emptyColumn) {
        try renderer.render(
            SQLSelect(
                table: "samples",
                columns: ["id"],
                orderings: [SQLOrdering(column: "")]
            )
        )
    }
    #expect(throws: SQLRenderError.identifierContainsNullByte) {
        try renderer.render(SQLSelect(table: "samples\0hidden", columns: ["id"]))
    }
    #expect(throws: SQLRenderError.negativeLimit(-1)) {
        try renderer.render(SQLSelect(table: "samples", columns: ["id"], limit: -1))
    }
    #expect(throws: SQLRenderError.negativeOffset(-1)) {
        try renderer.render(SQLSelect(table: "samples", columns: ["id"], limit: 1, offset: -1))
    }
    #expect(throws: SQLRenderError.offsetRequiresLimit) {
        try renderer.render(SQLSelect(table: "samples", columns: ["id"], offset: 1))
    }
}

@Test
func countRendererQuotesIdentifiersAndBindsThePredicate() throws {
    let count = SQLCount(
        table: "user\"records",
        predicate: .and([
            .comparison(column: "is_active", op: .eq, value: .bool(true)),
            .inList(column: "nickname", values: [.text("one"), .null]),
        ])
    )

    let postgres = try SQLRenderer(dialect: PostgresDialect()).render(count)
    #expect(
        postgres == RenderedSQL(
            sql: "SELECT COUNT(*) AS \"count\" FROM \"user\"\"records\" WHERE (\"is_active\" = $1 AND (\"nickname\" IN ($2) OR \"nickname\" IS NULL))",
            parameters: [.bool(true), .text("one")]
        )
    )

    let sqlite = try SQLRenderer(dialect: SQLiteDialect()).render(count)
    #expect(
        sqlite == RenderedSQL(
            sql: "SELECT COUNT(*) AS \"count\" FROM \"user\"\"records\" WHERE (\"is_active\" = ? AND (\"nickname\" IN (?) OR \"nickname\" IS NULL))",
            parameters: postgres.parameters
        )
    )
}

@Test
func countRendererRejectsInvalidTableAndPredicateIdentifiers() {
    let renderer = SQLRenderer(dialect: SQLiteDialect())

    #expect(throws: SQLRenderError.emptyTable) {
        try renderer.render(SQLCount(table: ""))
    }
    #expect(throws: SQLRenderError.identifierContainsNullByte) {
        try renderer.render(SQLCount(table: "samples\0hidden"))
    }
    #expect(throws: SQLRenderError.emptyColumn) {
        try renderer.render(
            SQLCount(
                table: "samples",
                predicate: .comparison(column: "", op: .eq, value: .int(1))
            )
        )
    }
}

private struct StandardDialect: SQLDialect {
    let capabilities: DialectCapabilities = []

    func placeholder(at position: Int) -> String { ":\(position)" }
}

private enum SQLServerLikeError: Error, Equatable {
    case offsetRequiresOrdering
}

private struct SQLServerLikeDialect: SQLDialect {
    let capabilities: DialectCapabilities = []

    func placeholder(at position: Int) -> String { ":\(position)" }

    func paginationPlan(
        limit: Int,
        offset: Int?,
        context: SQLPaginationContext
    ) throws -> SQLPaginationPlan {
        guard let offset else {
            return SQLPaginationPlan(
                placement: .afterSelect,
                fragments: [
                    .literal("TOP ("),
                    .parameter(limit),
                    .literal(")"),
                ]
            )
        }
        guard context.hasOrderings else {
            throw SQLServerLikeError.offsetRequiresOrdering
        }
        return SQLPaginationPlan(
            placement: .suffix,
            fragments: [
                .literal("OFFSET "),
                .parameter(offset),
                .literal(" ROWS FETCH NEXT "),
                .parameter(limit),
                .literal(" ROWS ONLY"),
            ]
        )
    }
}
