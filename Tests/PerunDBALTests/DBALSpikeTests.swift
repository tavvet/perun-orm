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

@Test
func sqliteAdapterKeepsGeneratedRowIDHintsScoped() async throws {
    let database = SQLiteDatabase(configuration: .memory(), maxConnections: 1)
    do {
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
    } catch {
        await database.shutdown()
        throw error
    }

    await database.shutdown()
}

@Test
func sqliteAdapterDefaultsToOneConnection() {
    #expect(SQLiteDatabase.defaultMaxConnections == 1)
}

@Test
func adapterDatabasesAdoptInjectedClientLifecycle() async throws {
    let sqliteClient = SQLiteClient(configuration: .memory(), maxConnections: 1)
    let sqliteDatabase = SQLiteDatabase(client: sqliteClient)
    await sqliteDatabase.shutdown()

    do {
        _ = try await sqliteClient.query("SELECT 1")
        Issue.record("SQLiteDatabase.shutdown() did not shut down its injected client")
    } catch let error as PerunSQLite.PerunError {
        #expect(error == .clientShutdown)
    }

    let postgresClient = PostgresClient(
        configuration: ConnectionConfiguration(
            user: "perun",
            database: "perun",
            tlsMode: .disable
        ),
        maxConnections: 1
    )
    let postgresDatabase = PostgresDatabase(client: postgresClient)
    await postgresDatabase.shutdown()

    do {
        _ = try await postgresClient.query("SELECT 1")
        Issue.record("PostgresDatabase.shutdown() did not shut down its injected client")
    } catch let error as PerunPGSQL.PerunError {
        guard case .clientShutdown = error else {
            Issue.record("unexpected PostgreSQL client error after shutdown: \(error)")
            return
        }
    }
}
