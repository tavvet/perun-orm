import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
import Testing

@Test
func insertRendererQuotesIdentifiersAndBindsValuesInColumnOrder() throws {
    let values = [
        SQLColumnValue(column: "display\"name", value: .text("Perun")),
        SQLColumnValue(column: "rank", value: .int(7)),
        SQLColumnValue(column: "deleted_at", value: .null),
    ]

    let postgres = try SQLRenderer(dialect: PostgresDialect()).render(
        SQLInsert(
            table: "user\"records",
            values: values,
            returning: ["id", "display\"name"]
        )
    )
    #expect(
        postgres == RenderedSQL(
            sql: "INSERT INTO \"user\"\"records\" (\"display\"\"name\", \"rank\", \"deleted_at\") VALUES ($1, $2, $3) RETURNING \"id\", \"display\"\"name\"",
            parameters: [.text("Perun"), .int(7), .null]
        )
    )

    let sqlite = try SQLRenderer(dialect: SQLiteDialect()).render(
        SQLInsert(table: "user\"records", values: values)
    )
    #expect(
        sqlite == RenderedSQL(
            sql: "INSERT INTO \"user\"\"records\" (\"display\"\"name\", \"rank\", \"deleted_at\") VALUES (?, ?, ?)",
            parameters: postgres.parameters
        )
    )
}

@Test
func insertRendererSupportsDefaultValuesAndReturning() throws {
    let postgres = try SQLRenderer(dialect: PostgresDialect()).render(
        SQLInsert(table: "samples", values: [], returning: ["id"])
    )

    #expect(
        postgres == RenderedSQL(
            sql: "INSERT INTO \"samples\" DEFAULT VALUES RETURNING \"id\"",
            parameters: []
        )
    )

    let sqlite = try SQLRenderer(dialect: SQLiteDialect()).render(
        SQLInsert(table: "samples", values: [])
    )
    #expect(
        sqlite == RenderedSQL(
            sql: "INSERT INTO \"samples\" DEFAULT VALUES",
            parameters: []
        )
    )
}

@Test
func insertRendererSupportsReturningBeforeTheValueSource() throws {
    let rendered = try SQLRenderer(dialect: OutputDialect()).render(
        SQLInsert(
            table: "samples",
            values: [SQLColumnValue(column: "status", value: .text("active"))],
            returning: ["id", "status"]
        )
    )

    #expect(
        rendered == RenderedSQL(
            sql: "INSERT INTO \"samples\" (\"status\") OUTPUT INSERTED.\"id\", INSERTED.\"status\" VALUES (:1)",
            parameters: [.text("active")]
        )
    )
}

@Test
func insertRendererRejectsStructurallyInvalidStatements() {
    let postgres = SQLRenderer(dialect: PostgresDialect())
    let sqlite = SQLRenderer(dialect: SQLiteDialect())

    #expect(throws: SQLRenderError.emptyTable) {
        try postgres.render(SQLInsert(table: "", values: []))
    }
    #expect(throws: SQLRenderError.emptyColumn) {
        try postgres.render(
            SQLInsert(table: "samples", values: [SQLColumnValue(column: "", value: .int(1))])
        )
    }
    #expect(throws: SQLRenderError.identifierContainsNullByte) {
        try postgres.render(
            SQLInsert(
                table: "samples",
                values: [SQLColumnValue(column: "visible\0hidden", value: .int(1))]
            )
        )
    }
    #expect(throws: SQLRenderError.duplicateInsertColumn("NAME")) {
        try postgres.render(
            SQLInsert(
                table: "samples",
                values: [
                    SQLColumnValue(column: "name", value: .text("first")),
                    SQLColumnValue(column: "NAME", value: .text("second")),
                ]
            )
        )
    }
    #expect(throws: SQLRenderError.emptyColumn) {
        try postgres.render(SQLInsert(table: "samples", values: [], returning: [""]))
    }
    #expect(throws: SQLRenderError.returningUnsupported) {
        try sqlite.render(SQLInsert(table: "samples", values: [], returning: ["id"]))
    }
}

private struct OutputDialect: SQLDialect {
    let capabilities: DialectCapabilities = [.returning]

    func placeholder(at position: Int) -> String { ":\(position)" }

    func insertReturningPlan(columns: [String]) -> SQLInsertReturningPlan? {
        var fragments: [SQLInsertReturningFragment] = [.literal("OUTPUT ")]
        for (index, column) in columns.enumerated() {
            if index > 0 {
                fragments.append(.literal(", "))
            }
            fragments.append(contentsOf: [
                .literal("INSERTED."),
                .column(column),
            ])
        }
        return SQLInsertReturningPlan(placement: .beforeValues, fragments: fragments)
    }
}
