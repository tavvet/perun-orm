import Foundation
import PerunDBAL
@testable import PerunDBALPostgres
import PerunDBALSQLite
import PerunPGSQL
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
func postgresAdapterPreservesPortableTimestampAndCommandSemantics() throws {
    #expect(postgresRowsAffected(from: "INSERT 0 1") == 1)
    #expect(postgresRowsAffected(from: "UPDATE 0") == 0)
    #expect(postgresRowsAffected(from: "DELETE 12") == 12)
    #expect(postgresRowsAffected(from: "SELECT 3") == 0)
    #expect(postgresRowsAffected(from: "CREATE TABLE") == 0)
    #expect(postgresRowsAffected(from: "INSERT malformed") == nil)

    let epoch = SQLTimestamp(microsecondsSinceUnixEpoch: 0)
    let parameters = try postgresParameters([.null, .date(epoch), .int(42)])
    #expect(parameters.count == 3)
    #expect(parameters[0] == nil)

    let encodedEpoch = try #require(parameters[1])
    #expect(encodedEpoch.postgresTypeOID == PostgresOID.timestamptz)
    #expect(encodedEpoch.postgresText == "1970-01-01 00:00:00.000000+00")
    let epochBinary = try #require(encodedEpoch.postgresBinary())
    #expect(try PostgresTimestampCodec.decodeBinary(epochBinary, column: "created_at") == epoch)

    let encodedInteger = try #require(parameters[2])
    #expect(encodedInteger.postgresTypeOID == 0)
    #expect(encodedInteger.postgresText == "42")
    #expect(encodedInteger.postgresBinary() == nil)

    let minimum = SQLTimestamp(microsecondsSinceUnixEpoch: -62_135_596_800_000_000)
    let encodedMinimum = try PostgresTimestampCodec.parameter(minimum)
    #expect(encodedMinimum.postgresText == "0001-01-01 00:00:00.000000+00")
    #expect(
        try PostgresTimestampCodec.decodeBinary(
            #require(encodedMinimum.postgresBinary()),
            column: "created_at"
        ) == minimum
    )

    let maximum = SQLTimestamp(microsecondsSinceUnixEpoch: 253_402_300_799_999_999)
    let encodedMaximum = try PostgresTimestampCodec.parameter(maximum)
    #expect(encodedMaximum.postgresText == "9999-12-31 23:59:59.999999+00")
    #expect(
        try PostgresTimestampCodec.decodeBinary(
            #require(encodedMaximum.postgresBinary()),
            column: "created_at"
        ) == maximum
    )

    #expect(throws: SQLValueBindingError.timestampOutOfRange) {
        try postgresParameters([
            .date(SQLTimestamp(microsecondsSinceUnixEpoch: .max)),
        ])
    }
    #expect(throws: PostgresAdapterError.invalidTimestamp(column: "created_at")) {
        try PostgresTimestampCodec.decodeBinary(
            withUnsafeBytes(of: Int64.max.bigEndian) { Array($0) },
            column: "created_at"
        )
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresAdapterExecutesPortableValuesAgainstLiveServer() async throws {
    let database = PostgresDatabase(
        configuration: postgresIntegrationConfiguration(),
        maxConnections: 1
    )
    let uuid = try #require(UUID(uuidString: "d7a42f38-c223-4f8c-bb11-cf304b086b3a"))
    let date = Date(timeIntervalSince1970: 4_368_673_968.123_222)
    let payload: [UInt8] = [0, 1, 2, 255]

    do {
        let result = try await database.execute(
            """
            SELECT $1 AS flag,
                   $2::integer AS small,
                   $3::bigint AS large,
                   $4 AS score,
                   $5 AS name,
                   $6 AS payload,
                   $7 AS created_at,
                   $8 AS token,
                   $9::text AS absent
            """,
            [
                .bool(true),
                .int(42),
                .int(Int64.max),
                .double(.infinity),
                .text("perun"),
                .blob(payload),
                date.sqlValue,
                .uuid(uuid),
                .null,
            ]
        )
        #expect(result.rowsAffected == 0)
        let row = try #require(result.rows.first)
        #expect(try row.decode("flag", as: Bool.self))
        #expect(try row.decode("small", as: Int32.self) == 42)
        #expect(try row.decode("large", as: Int64.self) == .max)
        #expect(try row.decode("score", as: Double.self).isInfinite)
        #expect(try row.decode("name", as: String.self) == "perun")
        #expect(try row.decode("payload", as: [UInt8].self) == payload)
        #expect(try row.decode("created_at", as: Date.self).sqlValue == date.sqlValue)
        #expect(try row.decode("token", as: UUID.self) == uuid)
        #expect(try row.decode("absent", as: String?.self) == nil)
        #expect(try row.decodeIfPresent("absent", as: String.self) == nil)

        let transactionResult = try await database.withTransaction { transaction in
            try await transaction.execute("SELECT 1::bigint AS value", [])
        }
        let transactionRow = try #require(transactionResult.rows.first)
        #expect(try transactionRow.decode("value", as: Int64.self) == 1)
    } catch {
        await database.shutdown()
        throw error
    }

    await database.shutdown()
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

private func postgresIntegrationConfiguration() -> ConnectionConfiguration {
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
