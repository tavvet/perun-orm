import Foundation
import PerunDBAL
import PerunPGSQL

public enum PostgresAdapterError: Error, Sendable, Equatable {
    case typeMismatch(column: String, expected: ColumnType, actualOID: Int32)
    case invalidTimestamp(column: String)
    case timestampOutOfRange
    case unsupportedResultFormat(column: String, formatCode: Int16)
}

/// DBAL façade over the standalone PostgreSQL connection pool.
public struct PostgresDatabase: Database {
    private let client: PostgresClient

    public var dialect: any SQLDialect { PostgresDialect() }

    public init(client: PostgresClient) {
        self.client = client
    }

    public init(
        configuration: ConnectionConfiguration,
        maxConnections: Int = 10,
        maxConnectionLifetime: Duration? = nil,
        maxIdleTime: Duration? = nil
    ) {
        self.init(
            client: PostgresClient(
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
        let result = try await client.query(
            sql,
            try postgresParameters(parameters),
            parameterFormat: .binary,
            resultFormat: .binary
        )
        return normalize(result)
    }

    public func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        try await client.withTransaction { transaction in
            try await body(PostgresTransaction(base: transaction))
        }
    }

    public func shutdown() async {
        await client.shutdown()
    }
}

private struct PostgresTransaction: Transaction {
    let base: PostgresConnection.Transaction

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        let result = try await base.query(
            sql,
            try postgresParameters(parameters),
            parameterFormat: .binary,
            resultFormat: .binary
        )
        return normalize(result)
    }
}

private struct PostgresDBALRow: Row {
    let base: PostgresRow

    func decode<T: SQLValueConvertible>(_ column: String, as type: T.Type) throws -> T {
        let cell = try base.cell(column)
        if cell.isNull {
            return try T(sqlValue: .null)
        }
        return try T(sqlValue: decodeValue(cell, column: column, as: T.columnType))
    }

    func decodeIfPresent<T: SQLValueConvertible>(_ column: String, as type: T.Type) throws -> T? {
        let cell = try base.cell(column)
        guard !cell.isNull else { return nil }
        return try T(sqlValue: decodeValue(cell, column: column, as: T.columnType))
    }

    private func decodeValue(
        _ cell: PostgresCell,
        column: String,
        as type: ColumnType
    ) throws -> SQLValue {
        let oid = cell.column.dataTypeOID
        switch type {
        case .boolean:
            try requireOID(PostgresOID.bool, actual: oid, column: column, expected: type)
            return .bool(try cell.decode(Bool.self))
        case .int32:
            try requireOID(PostgresOID.int4, actual: oid, column: column, expected: type)
            return .int(Int64(try cell.decode(Int32.self)))
        case .int64:
            try requireOID(PostgresOID.int8, actual: oid, column: column, expected: type)
            return .int(try cell.decode(Int64.self))
        case .double:
            try requireOID(PostgresOID.float8, actual: oid, column: column, expected: type)
            return .double(try cell.decode(Double.self))
        case .text:
            try requireOID(PostgresOID.text, actual: oid, column: column, expected: type)
            return .text(try cell.decode(String.self))
        case .blob:
            try requireOID(PostgresOID.bytea, actual: oid, column: column, expected: type)
            return .blob(try cell.decode([UInt8].self))
        case .timestamp:
            try requireOID(PostgresOID.timestamptz, actual: oid, column: column, expected: type)
            guard cell.column.formatCode == 1 else {
                throw PostgresAdapterError.unsupportedResultFormat(
                    column: column,
                    formatCode: cell.column.formatCode
                )
            }
            guard let bytes = cell.bytes else {
                throw PostgresAdapterError.invalidTimestamp(column: column)
            }
            return .date(try PostgresTimestampCodec.decodeBinary(bytes, column: column))
        case .uuid:
            try requireOID(PostgresOID.uuid, actual: oid, column: column, expected: type)
            return .uuid(try cell.decode(UUID.self))
        }
    }

    private func requireOID(
        _ expectedOID: Int32,
        actual: Int32,
        column: String,
        expected: ColumnType
    ) throws {
        guard actual == expectedOID else {
            throw PostgresAdapterError.typeMismatch(
                column: column,
                expected: expected,
                actualOID: actual
            )
        }
    }
}

func postgresParameters(_ values: [SQLValue]) throws -> [(any PostgresEncodable)?] {
    try values.map(postgresParameter)
}

private func postgresParameter(_ value: SQLValue) throws -> (any PostgresEncodable)? {
    try value.validateForPortableBinding()

    switch value {
    case .null:
        return nil
    case let .bool(value):
        return value
    case let .int(value):
        return PostgresIntegerParameter(value)
    case let .double(value):
        return value
    case let .text(value):
        return value
    case let .blob(value):
        return value
    case let .date(value):
        return try PostgresTimestampCodec.parameter(value)
    case let .uuid(value):
        return value
    }
}

/// `.int` is shared by portable `int32` and `int64`; OID 0 lets PostgreSQL infer the
/// concrete width from the statement instead of forcing every value to `int8`.
struct PostgresIntegerParameter: PostgresEncodable {
    let postgresText: String?

    init(_ value: Int64) {
        postgresText = String(value)
    }
}

private func normalize(_ result: PerunPGSQL.QueryResult) -> ExecResult {
    ExecResult(
        rows: result.rows.map { PostgresDBALRow(base: $0) },
        rowsAffected: postgresRowsAffected(from: result.commandTag)
    )
}

func postgresRowsAffected(from commandTag: String) -> Int? {
    let components = commandTag.split(separator: " ")
    guard let command = components.first else { return 0 }

    switch command {
    case "INSERT", "UPDATE", "DELETE", "MERGE", "COPY":
        guard let countText = components.last,
              let count = Int(countText),
              count >= 0
        else {
            return nil
        }
        return count
    default:
        return 0
    }
}

struct PostgresTimestampParameter: PostgresEncodable {
    let postgresText: String?
    let postgresTypeOID: Int32 = PostgresOID.timestamptz
    private let binary: [UInt8]

    init(text: String, binary: [UInt8]) {
        postgresText = text
        self.binary = binary
    }

    func postgresBinary() -> [UInt8]? { binary }
}

enum PostgresTimestampCodec {
    private static let postgresEpochOffsetMicroseconds: Int64 = 946_684_800_000_000

    static func parameter(_ timestamp: SQLTimestamp) throws -> PostgresTimestampParameter {
        try SQLValue.date(timestamp).validateForPortableBinding()
        guard let unixMicroseconds = timestamp.microsecondsSinceUnixEpoch else {
            throw PostgresAdapterError.timestampOutOfRange
        }
        let (postgresMicroseconds, overflow) = unixMicroseconds.subtractingReportingOverflow(
            postgresEpochOffsetMicroseconds
        )
        guard !overflow else {
            throw PostgresAdapterError.timestampOutOfRange
        }
        return PostgresTimestampParameter(
            text: text(unixMicroseconds: unixMicroseconds),
            binary: withUnsafeBytes(of: postgresMicroseconds.bigEndian) { Array($0) }
        )
    }

    static func decodeBinary(_ bytes: [UInt8], column: String) throws -> SQLTimestamp {
        guard bytes.count == 8 else {
            throw PostgresAdapterError.invalidTimestamp(column: column)
        }
        var bits: UInt64 = 0
        for byte in bytes {
            bits = (bits << 8) | UInt64(byte)
        }
        let postgresMicroseconds = Int64(bitPattern: bits)
        guard postgresMicroseconds != .min, postgresMicroseconds != .max else {
            throw PostgresAdapterError.invalidTimestamp(column: column)
        }
        let (unixMicroseconds, overflow) = postgresMicroseconds.addingReportingOverflow(
            postgresEpochOffsetMicroseconds
        )
        guard !overflow else {
            throw PostgresAdapterError.timestampOutOfRange
        }

        let timestamp = SQLTimestamp(microsecondsSinceUnixEpoch: unixMicroseconds)
        do {
            try SQLValue.date(timestamp).validateForPortableBinding()
        } catch {
            throw PostgresAdapterError.timestampOutOfRange
        }
        return timestamp
    }

    private static func text(unixMicroseconds totalMicroseconds: Int64) -> String {
        var seconds = totalMicroseconds / 1_000_000
        var microseconds = totalMicroseconds % 1_000_000
        if microseconds < 0 {
            microseconds += 1_000_000
            seconds -= 1
        }

        var days = seconds / 86_400
        var secondOfDay = seconds % 86_400
        if secondOfDay < 0 {
            secondOfDay += 86_400
            days -= 1
        }
        let (year, month, day) = civilFromDays(Int(days))
        return "\(pad(year, to: 4))-\(pad(month, to: 2))-\(pad(day, to: 2)) "
            + "\(pad(Int(secondOfDay) / 3_600, to: 2)):"
            + "\(pad((Int(secondOfDay) % 3_600) / 60, to: 2)):"
            + "\(pad(Int(secondOfDay) % 60, to: 2))."
            + "\(pad(Int(microseconds), to: 6))+00"
    }

    private static func pad(_ value: Int, to width: Int) -> String {
        let value = String(value)
        return String(repeating: "0", count: max(0, width - value.count)) + value
    }

    private static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shiftedDays = days + 719_468
        let era = (shiftedDays >= 0 ? shiftedDays : shiftedDays - 146_096) / 146_097
        let dayOfEra = shiftedDays - era * 146_097
        let yearOfEra = (
            dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096
        ) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (
            365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100
        )
        let monthPortion = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPortion + 2) / 5 + 1
        let month = monthPortion < 10 ? monthPortion + 3 : monthPortion - 9
        return (month <= 2 ? year + 1 : year, month, day)
    }
}
