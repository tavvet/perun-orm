import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
import Testing

@Test
func updateRendererQuotesIdentifiersAndBindsSetBeforePredicate() throws {
    let update = SQLUpdate(
        table: "user\"records",
        assignments: [
            SQLColumnValue(column: "display\"name", value: .text("Perun")),
            SQLColumnValue(column: "deleted_at", value: .null),
        ],
        predicate: .and([
            .comparison(column: "id", op: .eq, value: .int(7)),
            .comparison(column: "status", op: .neq, value: .null),
        ]),
        returning: ["id", "display\"name"]
    )

    let postgres = try SQLRenderer(dialect: PostgresDialect()).render(update)
    #expect(
        postgres == RenderedSQL(
            sql: "UPDATE \"user\"\"records\" SET \"display\"\"name\" = $1, \"deleted_at\" = $2 WHERE (\"id\" = $3 AND \"status\" IS NOT NULL) RETURNING \"id\", \"display\"\"name\"",
            parameters: [.text("Perun"), .null, .int(7)]
        )
    )

    let sqlite = try SQLRenderer(dialect: SQLiteDialect()).render(
        SQLUpdate(
            table: update.table,
            assignments: update.assignments,
            predicate: update.predicate
        )
    )
    #expect(
        sqlite == RenderedSQL(
            sql: "UPDATE \"user\"\"records\" SET \"display\"\"name\" = ?, \"deleted_at\" = ? WHERE (\"id\" = ? AND \"status\" IS NOT NULL)",
            parameters: postgres.parameters
        )
    )
}

@Test
func updateRendererAllowsAnExplicitWholeTableUpdate() throws {
    let rendered = try SQLRenderer(dialect: PostgresDialect()).render(
        SQLUpdate(
            table: "samples",
            assignments: [SQLColumnValue(column: "active", value: .bool(false))],
            predicate: nil
        )
    )

    #expect(
        rendered == RenderedSQL(
            sql: "UPDATE \"samples\" SET \"active\" = $1",
            parameters: [.bool(false)]
        )
    )
}

@Test
func updateRendererSupportsReturningBeforeThePredicate() throws {
    let rendered = try SQLRenderer(dialect: UpdateOutputDialect()).render(
        SQLUpdate(
            table: "samples",
            assignments: [SQLColumnValue(column: "status", value: .text("active"))],
            predicate: .comparison(column: "id", op: .eq, value: .int(7)),
            returning: ["id", "status"]
        )
    )

    #expect(
        rendered == RenderedSQL(
            sql: "UPDATE \"samples\" SET \"status\" = :1 OUTPUT INSERTED.\"id\", INSERTED.\"status\" WHERE \"id\" = :2",
            parameters: [.text("active"), .int(7)]
        )
    )
}

@Test
func updateRendererRejectsStructurallyInvalidStatements() {
    let postgres = SQLRenderer(dialect: PostgresDialect())
    let sqlite = SQLRenderer(dialect: SQLiteDialect())

    #expect(throws: SQLRenderError.emptyTable) {
        try postgres.render(
            SQLUpdate(
                table: "",
                assignments: [SQLColumnValue(column: "name", value: .text("Perun"))],
                predicate: nil
            )
        )
    }
    #expect(throws: SQLRenderError.noUpdatedColumns) {
        try postgres.render(SQLUpdate(table: "samples", assignments: [], predicate: nil))
    }
    #expect(throws: SQLRenderError.emptyColumn) {
        try postgres.render(
            SQLUpdate(
                table: "samples",
                assignments: [SQLColumnValue(column: "", value: .text("Perun"))],
                predicate: nil
            )
        )
    }
    #expect(throws: SQLRenderError.duplicateUpdateColumn("NAME")) {
        try postgres.render(
            SQLUpdate(
                table: "samples",
                assignments: [
                    SQLColumnValue(column: "name", value: .text("first")),
                    SQLColumnValue(column: "NAME", value: .text("second")),
                ],
                predicate: nil
            )
        )
    }
    #expect(throws: SQLRenderError.identifierContainsNullByte) {
        try postgres.render(
            SQLUpdate(
                table: "samples",
                assignments: [SQLColumnValue(column: "name", value: .text("Perun"))],
                predicate: nil,
                returning: ["visible\0hidden"]
            )
        )
    }
    #expect(throws: SQLRenderError.returningUnsupported) {
        try sqlite.render(
            SQLUpdate(
                table: "samples",
                assignments: [SQLColumnValue(column: "name", value: .text("Perun"))],
                predicate: nil,
                returning: ["id"]
            )
        )
    }
}

private struct UpdateOutputDialect: SQLDialect {
    let capabilities: DialectCapabilities = [.returning]

    func placeholder(at position: Int) -> String { ":\(position)" }

    func updateReturningPlan(columns: [String]) -> SQLDMLReturningPlan? {
        var fragments: [SQLDMLReturningFragment] = [.literal("OUTPUT ")]
        for (index, column) in columns.enumerated() {
            if index > 0 {
                fragments.append(.literal(", "))
            }
            fragments.append(contentsOf: [
                .literal("INSERTED."),
                .column(column),
            ])
        }
        return SQLDMLReturningPlan(placement: .embedded, fragments: fragments)
    }
}
