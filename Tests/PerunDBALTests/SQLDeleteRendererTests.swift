import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
import Testing

@Test
func deleteRendererQuotesIdentifiersAndBindsPredicateInOrder() throws {
    let delete = SQLDelete(
        table: "user\"records",
        predicate: .and([
            .comparison(column: "id", op: .eq, value: .int(7)),
            .inList(column: "role", values: [.text("admin"), .null, .text("editor")]),
        ]),
        returning: ["id", "display\"name"]
    )

    let postgres = try SQLRenderer(dialect: PostgresDialect()).render(delete)
    #expect(
        postgres == RenderedSQL(
            sql: "DELETE FROM \"user\"\"records\" WHERE (\"id\" = $1 AND (\"role\" IN ($2, $3) OR \"role\" IS NULL)) RETURNING \"id\", \"display\"\"name\"",
            parameters: [.int(7), .text("admin"), .text("editor")]
        )
    )

    let sqlite = try SQLRenderer(dialect: SQLiteDialect()).render(
        SQLDelete(table: delete.table, predicate: delete.predicate)
    )
    #expect(
        sqlite == RenderedSQL(
            sql: "DELETE FROM \"user\"\"records\" WHERE (\"id\" = ? AND (\"role\" IN (?, ?) OR \"role\" IS NULL))",
            parameters: postgres.parameters
        )
    )
}

@Test
func deleteRendererAllowsAnExplicitWholeTableDelete() throws {
    let rendered = try SQLRenderer(dialect: PostgresDialect()).render(
        SQLDelete(table: "samples", predicate: nil)
    )

    #expect(
        rendered == RenderedSQL(
            sql: "DELETE FROM \"samples\"",
            parameters: []
        )
    )
}

@Test
func deleteRendererSupportsReturningBeforeThePredicate() throws {
    let rendered = try SQLRenderer(dialect: DeleteOutputDialect()).render(
        SQLDelete(
            table: "samples",
            predicate: .comparison(column: "id", op: .eq, value: .int(7)),
            returning: ["id", "status"]
        )
    )

    #expect(
        rendered == RenderedSQL(
            sql: "DELETE FROM \"samples\" OUTPUT DELETED.\"id\", DELETED.\"status\" WHERE \"id\" = :1",
            parameters: [.int(7)]
        )
    )
}

@Test
func deleteRendererRejectsStructurallyInvalidStatements() {
    let postgres = SQLRenderer(dialect: PostgresDialect())
    let sqlite = SQLRenderer(dialect: SQLiteDialect())

    #expect(throws: SQLRenderError.emptyTable) {
        try postgres.render(SQLDelete(table: "", predicate: nil))
    }
    #expect(throws: SQLRenderError.emptyColumn) {
        try postgres.render(
            SQLDelete(
                table: "samples",
                predicate: .null(column: "", negated: false)
            )
        )
    }
    #expect(throws: SQLRenderError.identifierContainsNullByte) {
        try postgres.render(
            SQLDelete(
                table: "samples",
                predicate: nil,
                returning: ["visible\0hidden"]
            )
        )
    }
    #expect(throws: SQLRenderError.returningUnsupported) {
        try sqlite.render(
            SQLDelete(table: "samples", predicate: nil, returning: ["id"])
        )
    }
}

private struct DeleteOutputDialect: SQLDialect {
    let capabilities: DialectCapabilities = [.returning]

    func placeholder(at position: Int) -> String { ":\(position)" }

    func deleteReturningPlan(columns: [String]) -> SQLDMLReturningPlan? {
        var fragments: [SQLDMLReturningFragment] = [.literal("OUTPUT ")]
        for (index, column) in columns.enumerated() {
            if index > 0 {
                fragments.append(.literal(", "))
            }
            fragments.append(contentsOf: [
                .literal("DELETED."),
                .column(column),
            ])
        }
        return SQLDMLReturningPlan(placement: .embedded, fragments: fragments)
    }
}
