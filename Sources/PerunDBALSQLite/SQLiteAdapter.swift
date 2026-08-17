import Foundation
import PerunDBAL
import PerunSQLite

public struct SQLiteDialect: SQLDialect {
    // RETURNING stays disabled until the driver exposes the runtime SQLite version (>= 3.35).
    public let capabilities: DialectCapabilities = [
        .lastInsertRowID,
    ]

    public init() {}

    public func placeholder(at position: Int) -> String {
        precondition(position > 0, "placeholder positions are one-based")
        return "?"
    }
}

public enum SQLiteAdapterError: Error, Sendable, Equatable {
    case typeMismatch(column: String, expected: ColumnType)
    case invalidBoolean(column: String, value: Int64)
    case invalidTimestamp(column: String)
    case invalidUUID(column: String)
    case timestampOutOfRange
}

/// DBAL façade over the standalone SQLite connection pool.
public struct SQLiteDatabase: Database {
    private let client: SQLiteClient

    public var dialect: any SQLDialect { SQLiteDialect() }

    public init(client: SQLiteClient) {
        self.client = client
    }

    public init(
        configuration: SQLiteConfiguration,
        maxConnections: Int = 10,
        maxConnectionLifetime: Duration? = nil,
        maxIdleTime: Duration? = nil
    ) {
        self.init(
            client: SQLiteClient(
                configuration: configuration,
                maxConnections: maxConnections,
                maxConnectionLifetime: maxConnectionLifetime,
                maxIdleTime: maxIdleTime
            )
        )
    }

    public func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        let result = try await client.query(sql, try sqliteParameters(parameters))
        return normalize(result, intent: intent)
    }

    public func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        try await client.withTransaction { transaction in
            try await body(SQLiteTransaction(base: transaction))
        }
    }

    public func shutdown() async {
        await client.shutdown()
    }
}

private struct SQLiteTransaction: Transaction {
    let base: SQLiteConnection.Transaction

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        let result = try await base.query(sql, try sqliteParameters(parameters))
        return normalize(result, intent: intent)
    }
}

private struct SQLiteDBALRow: Row {
    let base: SQLiteRow

    func decode<T: SQLValueConvertible>(_ column: String, as type: T.Type) throws -> T {
        let cell = try base.cell(column)
        if cell.isNull {
            return try T(sqlValue: .null)
        }
        return try T(sqlValue: decodeValue(cell.value, column: column, as: T.columnType))
    }

    func decodeIfPresent<T: SQLValueConvertible>(_ column: String, as type: T.Type) throws -> T? {
        let cell = try base.cell(column)
        guard !cell.isNull else { return nil }
        return try T(sqlValue: decodeValue(cell.value, column: column, as: T.columnType))
    }

    private func decodeValue(
        _ value: SQLiteValue,
        column: String,
        as type: ColumnType
    ) throws -> SQLValue {
        switch (type, value) {
        case let (.boolean, .integer(raw)):
            switch raw {
            case 0: return .bool(false)
            case 1: return .bool(true)
            default: throw SQLiteAdapterError.invalidBoolean(column: column, value: raw)
            }
        case let (.int32, .integer(raw)), let (.int64, .integer(raw)):
            return .int(raw)
        case let (.double, .real(raw)):
            return .double(raw)
        case let (.text, .text(raw)):
            return .text(raw)
        case let (.blob, .blob(raw)):
            return .blob(raw)
        case let (.timestamp, .text(raw)):
            guard let timestamp = SQLiteDateCodec.decode(raw) else {
                throw SQLiteAdapterError.invalidTimestamp(column: column)
            }
            return .date(timestamp)
        case let (.uuid, .text(raw)):
            guard let uuid = UUID(uuidString: raw),
                  uuid.uuidString.lowercased() == raw
            else {
                throw SQLiteAdapterError.invalidUUID(column: column)
            }
            return .uuid(uuid)
        default:
            throw SQLiteAdapterError.typeMismatch(column: column, expected: type)
        }
    }
}

private struct SQLiteParameter: SQLiteEncodable {
    let value: SQLiteValue

    func encode() -> SQLiteValue { value }
}

private func sqliteParameters(_ values: [SQLValue]) throws -> [(any SQLiteEncodable)?] {
    try values.map(sqliteParameter)
}

private func sqliteParameter(_ value: SQLValue) throws -> (any SQLiteEncodable)? {
    try value.validateForPortableBinding()

    switch value {
    case .null:
        return nil
    case let .bool(value):
        return value
    case let .int(value):
        return value
    case let .double(value):
        return value
    case let .text(value):
        return value
    case let .blob(value):
        return value
    case let .date(value):
        return SQLiteParameter(value: .text(try SQLiteDateCodec.encode(value)))
    case let .uuid(value):
        return SQLiteParameter(value: .text(value.uuidString.lowercased()))
    }
}

private func normalize(
    _ result: PerunSQLite.QueryResult,
    intent: ExecutionIntent
) -> ExecResult {
    let rows: [any Row] = result.rows.map { SQLiteDBALRow(base: $0) }
    let lastInsertRowID: Int64?
    if intent == .generatedRowIDInsert, rows.isEmpty, result.rowsAffected == 1 {
        lastInsertRowID = result.lastInsertRowID
    } else {
        lastInsertRowID = nil
    }
    return ExecResult(
        rows: rows,
        rowsAffected: result.rowsAffected,
        lastInsertRowID: lastInsertRowID
    )
}

private enum SQLiteDateCodec {
    static func encode(_ timestamp: SQLTimestamp) throws -> String {
        guard let totalMicroseconds = timestamp.microsecondsSinceUnixEpoch else {
            throw SQLiteAdapterError.timestampOutOfRange
        }

        var seconds = totalMicroseconds / 1_000_000
        var microseconds = totalMicroseconds - seconds * 1_000_000
        if microseconds < 0 {
            microseconds += 1_000_000
            seconds -= 1
        }

        let days = Int((Double(seconds) / 86_400).rounded(.down))
        let secondOfDay = Int(seconds - Int64(days) * 86_400)
        let (year, month, day) = civilFromDays(days)
        guard (1 ... 9_999).contains(year) else {
            throw SQLiteAdapterError.timestampOutOfRange
        }

        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%06dZ",
            year,
            month,
            day,
            secondOfDay / 3_600,
            (secondOfDay % 3_600) / 60,
            secondOfDay % 60,
            Int(microseconds)
        )
    }

    static func decode(_ text: String) -> SQLTimestamp? {
        let bytes = Array(text.utf8)
        guard bytes.count == 27,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes[10] == 84,
              bytes[13] == 58,
              bytes[16] == 58,
              bytes[19] == 46,
              bytes[26] == 90,
              let year = integer(bytes, 0 ..< 4),
              let month = integer(bytes, 5 ..< 7),
              let day = integer(bytes, 8 ..< 10),
              let hour = integer(bytes, 11 ..< 13),
              let minute = integer(bytes, 14 ..< 16),
              let second = integer(bytes, 17 ..< 19),
              let microsecond = integer(bytes, 20 ..< 26),
              (1 ... 9_999).contains(year),
              (1 ... 12).contains(month),
              (1 ... daysInMonth(year: year, month: month)).contains(day),
              (0 ... 23).contains(hour),
              (0 ... 59).contains(minute),
              (0 ... 59).contains(second)
        else {
            return nil
        }

        let seconds = Int64(daysFromCivil(year: year, month: month, day: day)) * 86_400
            + Int64(hour * 3_600 + minute * 60 + second)
        let (wholeMicroseconds, multiplyOverflow) = seconds.multipliedReportingOverflow(
            by: 1_000_000
        )
        let (totalMicroseconds, addOverflow) = wholeMicroseconds.addingReportingOverflow(
            Int64(microsecond)
        )
        guard !multiplyOverflow, !addOverflow else { return nil }
        return SQLTimestamp(microsecondsSinceUnixEpoch: totalMicroseconds)
    }

    private static func integer(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        var result = 0
        for index in range {
            let byte = bytes[index]
            guard (48 ... 57).contains(byte) else { return nil }
            result = result * 10 + Int(byte - 48)
        }
        return result
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        case 2: isLeapYear(year) ? 29 : 28
        default: 0
        }
    }

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shiftedDays = days + 719_468
        let era = (shiftedDays >= 0 ? shiftedDays : shiftedDays - 146_096) / 146_097
        let dayOfEra = shiftedDays - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPortion = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPortion + 2) / 5 + 1
        let month = monthPortion < 10 ? monthPortion + 3 : monthPortion - 9
        return (month <= 2 ? year + 1 : year, month, day)
    }
}
