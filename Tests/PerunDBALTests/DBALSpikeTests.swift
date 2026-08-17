import Foundation
import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
import PerunSQLite
import Testing

@Test
func semanticValueConversionsAreStrict() throws {
    #expect(try Int32(sqlValue: .int(42)) == 42)
    #expect(try Optional<String>(sqlValue: .null) == nil)
    #expect(Optional("perun").sqlValue == .text("perun"))

    #expect(throws: SQLValueConversionError.self) {
        try Int32(sqlValue: .int(Int64.max))
    }
    #expect(throws: SQLValueConversionError.self) {
        try Bool(sqlValue: .int(1))
    }

    #expect(try Float(sqlValue: .double(.infinity)).isInfinite)
    #expect(try Float(sqlValue: .double(.nan)).isNaN)
    #expect(throws: SQLValueConversionError.self) {
        try Float(sqlValue: .double(.greatestFiniteMagnitude))
    }

    let driftRegression = Date(timeIntervalSince1970: 4_368_673_968.123_222)
    let timestamp = driftRegression.sqlValue
    let decodedTimestamp = try Date(sqlValue: timestamp)
    #expect(decodedTimestamp.sqlValue == timestamp)
    #expect(try Date(sqlValue: decodedTimestamp.sqlValue) == decodedTimestamp)

    let unrepresentableMicroseconds: Int64 = 253_402_300_799_000_001
    #expect(
        throws: SQLValueConversionError.timestampNotRepresentable(
            microsecondsSinceUnixEpoch: unrepresentableMicroseconds
        )
    ) {
        try Date(
            sqlValue: .date(
                SQLTimestamp(microsecondsSinceUnixEpoch: unrepresentableMicroseconds)
            )
        )
    }
}

@Test
func portableBindingRejectsValuesUnsupportedByEveryBackend() throws {
    #expect(throws: SQLValueBindingError.notANumber) {
        try SQLValue.double(.nan).validateForPortableBinding()
    }
    #expect(throws: SQLValueBindingError.nonFiniteTimestamp) {
        try Date(timeIntervalSinceReferenceDate: .infinity).sqlValue.validateForPortableBinding()
    }
    #expect(throws: SQLValueBindingError.timestampOutOfRange) {
        try Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude)
            .sqlValue
            .validateForPortableBinding()
    }
    #expect(throws: SQLValueBindingError.timestampOutOfRange) {
        try SQLValue.date(SQLTimestamp(microsecondsSinceUnixEpoch: .max))
            .validateForPortableBinding()
    }

    try SQLValue.double(.infinity).validateForPortableBinding()
    try SQLValue.date(
        SQLTimestamp(microsecondsSinceUnixEpoch: -62_135_596_800_000_000)
    ).validateForPortableBinding()
    try SQLValue.date(
        SQLTimestamp(microsecondsSinceUnixEpoch: 253_402_300_799_999_999)
    ).validateForPortableBinding()
}

@Test
func binderUsesTheInjectedDialect() {
    var postgres = ParamBinder(dialect: PostgresDialect())
    #expect(postgres.bind(.int(1)) == "$1")
    #expect(postgres.bind(.text("two")) == "$2")
    #expect(postgres.parameters == [.int(1), .text("two")])

    var sqlite = ParamBinder(dialect: SQLiteDialect())
    #expect(sqlite.bind(.int(1)) == "?")
    #expect(sqlite.bind(.int(2)) == "?")
    #expect(sqlite.parameters == [.int(1), .int(2)])

    #expect(PostgresDialect().quoteIdentifier("odd\"name") == "\"odd\"\"name\"")
    #expect(SQLiteDialect().quoteIdentifier("select") == "\"select\"")
    #expect(!SQLiteDialect().capabilities.contains(.returning))
    #expect(SQLiteDialect().capabilities.contains(.lastInsertRowID))
}

@Test
func sqliteAdapterExecutesPortableValuesAndRollsBack() async throws {
    let database = SQLiteDatabase(configuration: .memory(), maxConnections: 1)
    let uuid = try #require(UUID(uuidString: "d7a42f38-c223-4f8c-bb11-cf304b086b3a"))
    // Regression value: repeated Date-based microsecond normalization used to drift by 1 μs.
    let date = Date(timeIntervalSince1970: 4_368_673_968.123_222)

    do {
        _ = try await database.execute("SELECT ?", [.double(.nan)])
        Issue.record("SQLite adapter unexpectedly bound NaN")
    } catch let error as SQLValueBindingError {
        #expect(error == .notANumber)
    }
    do {
        _ = try await database.execute(
            "SELECT ?",
            [Date(timeIntervalSinceReferenceDate: .infinity).sqlValue]
        )
        Issue.record("SQLite adapter unexpectedly bound a non-finite timestamp")
    } catch let error as SQLValueBindingError {
        #expect(error == .nonFiniteTimestamp)
    }

    let infinityResult = try await database.execute("SELECT ? AS value", [.double(.infinity)])
    let infinityRow = try #require(infinityResult.rows.first)
    #expect(try infinityRow.decode("value", as: Double.self).isInfinite)

    _ = try await database.execute(
        "CREATE TABLE rowid_samples (id INTEGER PRIMARY KEY, token TEXT UNIQUE NOT NULL)",
        []
    )
    let firstRowID = try await database.execute(
        "INSERT INTO rowid_samples (token) VALUES (?)",
        [.text("duplicate")],
        intent: .generatedRowIDInsert
    )
    #expect(firstRowID.lastInsertRowID == 1)

    let ignoredInsert = try await database.execute(
        "INSERT OR IGNORE INTO rowid_samples (token) VALUES (?)",
        [.text("duplicate")],
        intent: .generatedRowIDInsert
    )
    #expect(ignoredInsert.rowsAffected == 0)
    #expect(ignoredInsert.lastInsertRowID == nil)

    let cteInsert = try await database.execute(
        "WITH value(token) AS (SELECT 'cte') INSERT INTO rowid_samples (token) SELECT token FROM value",
        [],
        intent: .generatedRowIDInsert
    )
    #expect(cteInsert.lastInsertRowID == 2)

    let arbitraryInsert = try await database.execute(
        "INSERT INTO rowid_samples (token) VALUES (?)",
        [.text("arbitrary")]
    )
    #expect(arbitraryInsert.rowsAffected == 1)
    #expect(arbitraryInsert.lastInsertRowID == nil)

    _ = try await database.execute(
        "CREATE TABLE without_rowid (id TEXT PRIMARY KEY) WITHOUT ROWID",
        []
    )
    let withoutRowID = try await database.execute(
        "INSERT INTO without_rowid (id) VALUES (?)",
        [.text("not-a-rowid-table")]
    )
    #expect(withoutRowID.rowsAffected == 1)
    #expect(withoutRowID.lastInsertRowID == nil)

    _ = try await database.execute(
        """
        CREATE TABLE samples (
            id INTEGER PRIMARY KEY,
            flag INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            token TEXT NOT NULL
        )
        """,
        []
    )

    let insert = try await database.execute(
        "INSERT INTO samples (flag, created_at, token) VALUES (?, ?, ?)",
        [.bool(true), date.sqlValue, .uuid(uuid)],
        intent: .generatedRowIDInsert
    )
    #expect(insert.rowsAffected == 1)
    #expect(insert.lastInsertRowID == 1)

    let selected = try await database.execute(
        "SELECT flag, created_at, token FROM samples WHERE id = ?",
        [.int(1)]
    )
    let row = try #require(selected.rows.first)
    let flag = try row.decode("flag", as: Bool.self)
    let storedDate = try row.decode("created_at", as: Date.self)
    let token = try row.decode("token", as: UUID.self)
    let normalizedDate = try Date(sqlValue: date.sqlValue)

    #expect(flag)
    #expect(storedDate == normalizedDate)
    #expect(token == uuid)

    do {
        let _: Void = try await database.withTransaction { transaction in
            _ = try await transaction.execute(
                "INSERT INTO samples (flag, created_at, token) VALUES (?, ?, ?)",
                [.bool(false), date.sqlValue, .uuid(uuid)]
            )
            throw RollbackProbe.expected
        }
        Issue.record("transaction unexpectedly committed")
    } catch RollbackProbe.expected {
        // Expected: the driver rolls the transaction back when the closure throws.
    }

    let countResult = try await database.execute("SELECT COUNT(*) AS count FROM samples", [])
    let countRow = try #require(countResult.rows.first)
    #expect(try countRow.decode("count", as: Int64.self) == 1)

    let lifecycle: any Database = database
    await lifecycle.shutdown()
}

private enum RollbackProbe: Error {
    case expected
}
