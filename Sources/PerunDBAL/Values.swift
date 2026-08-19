import Foundation

/// The portable column vocabulary shared by DBAL and ORM in v0.1.
public enum ColumnType: Sendable, Hashable {
    /// A boolean value.
    case boolean
    /// A signed 32-bit integer.
    case int32
    /// A signed 64-bit integer.
    case int64
    /// An IEEE-754 double-precision value.
    case double
    /// Unicode text.
    case text
    /// Arbitrary bytes.
    case blob
    /// A microsecond-precision timestamp.
    case timestamp
    /// A UUID value.
    case uuid
}

/// A semantic value at the neutral DBAL boundary.
public enum SQLValue: Sendable, Hashable {
    /// SQL `NULL` without an intrinsic column type.
    case null
    /// A boolean value.
    case bool(Bool)
    /// A signed integer represented at the neutral boundary as `Int64`.
    case int(Int64)
    /// A double-precision value.
    case double(Double)
    /// Unicode text.
    case text(String)
    /// Arbitrary bytes.
    case blob([UInt8])
    /// A lossless portable timestamp.
    case date(SQLTimestamp)
    /// A UUID value.
    case uuid(UUID)
}

/// A lossless timestamp carrier at the DBAL boundary.
public struct SQLTimestamp: Sendable, Hashable {
    private enum Storage: Sendable, Hashable {
        case microsecondsSinceUnixEpoch(Int64)
        case nonFinite
        case outOfRange
    }

    private static let referenceDateOffsetMicroseconds: Int64 = 978_307_200_000_000
    private static let minimumPortableMicroseconds: Int64 = -62_135_596_800_000_000
    private static let maximumPortableMicrosecondsExclusive: Int64 = 253_402_300_800_000_000
    private let storage: Storage

    /// Creates a timestamp from exact microseconds since the Unix epoch.
    ///
    /// Portable range validation occurs when the value is bound to a database.
    public init(microsecondsSinceUnixEpoch: Int64) {
        storage = .microsecondsSinceUnixEpoch(microsecondsSinceUnixEpoch)
    }

    /// Converts a Foundation `Date` to rounded Unix-epoch microseconds.
    ///
    /// Non-finite and unrepresentable inputs are retained as an invalid state and rejected by
    /// portable binding.
    public init(_ date: Date) {
        let referenceSeconds = date.timeIntervalSinceReferenceDate
        guard referenceSeconds.isFinite else {
            storage = .nonFinite
            return
        }
        guard let referenceMicroseconds = Int64(
            exactly: (referenceSeconds * 1_000_000).rounded()
        ) else {
            storage = .outOfRange
            return
        }
        let (unixMicroseconds, overflow) = referenceMicroseconds.addingReportingOverflow(
            Self.referenceDateOffsetMicroseconds
        )
        storage = overflow ? .outOfRange : .microsecondsSinceUnixEpoch(unixMicroseconds)
    }

    /// Exact microseconds since the Unix epoch, or `nil` for an invalid `Date` input.
    public var microsecondsSinceUnixEpoch: Int64? {
        guard case let .microsecondsSinceUnixEpoch(value) = storage else {
            return nil
        }
        return value
    }

    fileprivate var bindingError: SQLValueBindingError? {
        switch storage {
        case let .microsecondsSinceUnixEpoch(value)
            where value < Self.minimumPortableMicroseconds
                || value >= Self.maximumPortableMicrosecondsExclusive:
            .timestampOutOfRange
        case .microsecondsSinceUnixEpoch:
            nil
        case .nonFinite:
            .nonFiniteTimestamp
        case .outOfRange:
            .timestampOutOfRange
        }
    }

    fileprivate func exactDate() -> Date? {
        guard let unixMicroseconds = microsecondsSinceUnixEpoch else {
            return nil
        }
        let (targetReferenceMicroseconds, overflow) = unixMicroseconds
            .subtractingReportingOverflow(Self.referenceDateOffsetMicroseconds)
        guard !overflow else { return nil }

        // Division can land beside the representable Date that produced these microseconds.
        // Walk adjacent Double values, but reject database timestamps Date cannot express exactly.
        var candidateSeconds = Double(targetReferenceMicroseconds) / 1_000_000
        for _ in 0 ..< 16 {
            let candidate = Date(timeIntervalSinceReferenceDate: candidateSeconds)
            let encoded = SQLTimestamp(candidate)
            guard let actualMicroseconds = encoded.microsecondsSinceUnixEpoch else {
                return nil
            }
            if actualMicroseconds == unixMicroseconds {
                return candidate
            }
            candidateSeconds = actualMicroseconds < unixMicroseconds
                ? candidateSeconds.nextUp
                : candidateSeconds.nextDown
        }
        return nil
    }
}

/// Failures converting between a semantic ``SQLValue`` and a requested Swift type.
public enum SQLValueConversionError: Error, Sendable, Equatable {
    /// The semantic value does not match the requested portable column type.
    case typeMismatch(expected: ColumnType, actual: SQLValue)
    /// The semantic value cannot fit in the requested Swift target type.
    case outOfRange(target: String, actual: SQLValue)
    /// Foundation cannot represent the exact portable timestamp without precision loss.
    case timestampNotRepresentable(microsecondsSinceUnixEpoch: Int64)
}

/// Values rejected before backend-specific binding because they are not portable.
public enum SQLValueBindingError: Error, Sendable, Equatable {
    /// IEEE NaN has no supported portable database representation.
    case notANumber
    /// A timestamp was created from a non-finite Foundation `Date`.
    case nonFiniteTimestamp
    /// A timestamp lies outside the shared backend range.
    case timestampOutOfRange
}

public extension SQLValue {
    /// Enforces the subset that every supported backend can bind consistently.
    func validateForPortableBinding() throws {
        switch self {
        case let .double(value) where value.isNaN:
            throw SQLValueBindingError.notANumber
        case let .date(value):
            if let error = value.bindingError {
                throw error
            }
        default:
            break
        }
    }
}

/// Converts between a portable Swift value and its semantic DBAL representation.
public protocol SQLValueConvertible: Sendable {
    /// The portable schema type used for values of this Swift type.
    static var columnType: ColumnType { get }
    /// Whether this Swift type accepts and emits SQL `NULL`.
    static var isNullable: Bool { get }

    /// The semantic DBAL representation of this value.
    var sqlValue: SQLValue { get }
    /// Creates a Swift value from its strict semantic DBAL representation.
    init(sqlValue: SQLValue) throws
}

public extension SQLValueConvertible {
    static var isNullable: Bool { false }
}

extension Bool: SQLValueConvertible {
    public static var columnType: ColumnType { .boolean }
    public var sqlValue: SQLValue { .bool(self) }

    public init(sqlValue: SQLValue) throws {
        guard case let .bool(value) = sqlValue else {
            throw SQLValueConversionError.typeMismatch(expected: .boolean, actual: sqlValue)
        }
        self = value
    }
}

extension Int32: SQLValueConvertible {
    public static var columnType: ColumnType { .int32 }
    public var sqlValue: SQLValue { .int(Int64(self)) }

    public init(sqlValue: SQLValue) throws {
        guard case let .int(value) = sqlValue else {
            throw SQLValueConversionError.typeMismatch(expected: .int32, actual: sqlValue)
        }
        guard let converted = Int32(exactly: value) else {
            throw SQLValueConversionError.outOfRange(target: "Int32", actual: sqlValue)
        }
        self = converted
    }
}

extension Int64: SQLValueConvertible {
    public static var columnType: ColumnType { .int64 }
    public var sqlValue: SQLValue { .int(self) }

    public init(sqlValue: SQLValue) throws {
        guard case let .int(value) = sqlValue else {
            throw SQLValueConversionError.typeMismatch(expected: .int64, actual: sqlValue)
        }
        self = value
    }
}

extension Int: SQLValueConvertible {
    public static var columnType: ColumnType { .int64 }
    public var sqlValue: SQLValue { .int(Int64(self)) }

    public init(sqlValue: SQLValue) throws {
        guard case let .int(value) = sqlValue else {
            throw SQLValueConversionError.typeMismatch(expected: .int64, actual: sqlValue)
        }
        guard let converted = Int(exactly: value) else {
            throw SQLValueConversionError.outOfRange(target: "Int", actual: sqlValue)
        }
        self = converted
    }
}

extension Double: SQLValueConvertible {
    public static var columnType: ColumnType { .double }
    public var sqlValue: SQLValue { .double(self) }

    public init(sqlValue: SQLValue) throws {
        guard case let .double(value) = sqlValue else {
            throw SQLValueConversionError.typeMismatch(expected: .double, actual: sqlValue)
        }
        self = value
    }
}

extension Float: SQLValueConvertible {
    public static var columnType: ColumnType { .double }
    public var sqlValue: SQLValue { .double(Double(self)) }

    public init(sqlValue: SQLValue) throws {
        guard case let .double(value) = sqlValue else {
            throw SQLValueConversionError.typeMismatch(expected: .double, actual: sqlValue)
        }
        let converted = Float(value)
        guard !value.isFinite || converted.isFinite else {
            throw SQLValueConversionError.outOfRange(target: "Float", actual: sqlValue)
        }
        self = converted
    }
}

extension String: SQLValueConvertible {
    public static var columnType: ColumnType { .text }
    public var sqlValue: SQLValue { .text(self) }

    public init(sqlValue: SQLValue) throws {
        guard case let .text(value) = sqlValue else {
            throw SQLValueConversionError.typeMismatch(expected: .text, actual: sqlValue)
        }
        self = value
    }
}

extension Array: SQLValueConvertible where Element == UInt8 {
    public static var columnType: ColumnType { .blob }
    public var sqlValue: SQLValue { .blob(self) }

    public init(sqlValue: SQLValue) throws {
        guard case let .blob(value) = sqlValue else {
            throw SQLValueConversionError.typeMismatch(expected: .blob, actual: sqlValue)
        }
        self = value
    }
}

extension Data: SQLValueConvertible {
    public static var columnType: ColumnType { .blob }
    public var sqlValue: SQLValue { .blob(Array(self)) }

    public init(sqlValue: SQLValue) throws {
        guard case let .blob(value) = sqlValue else {
            throw SQLValueConversionError.typeMismatch(expected: .blob, actual: sqlValue)
        }
        self = Data(value)
    }
}

extension Date: SQLValueConvertible {
    public static var columnType: ColumnType { .timestamp }
    public var sqlValue: SQLValue { .date(SQLTimestamp(self)) }

    public init(sqlValue: SQLValue) throws {
        guard case let .date(timestamp) = sqlValue else {
            throw SQLValueConversionError.typeMismatch(expected: .timestamp, actual: sqlValue)
        }
        guard let microseconds = timestamp.microsecondsSinceUnixEpoch else {
            throw SQLValueConversionError.outOfRange(target: "Date", actual: sqlValue)
        }
        guard let date = timestamp.exactDate() else {
            throw SQLValueConversionError.timestampNotRepresentable(
                microsecondsSinceUnixEpoch: microseconds
            )
        }
        self = date
    }
}

extension UUID: SQLValueConvertible {
    public static var columnType: ColumnType { .uuid }
    public var sqlValue: SQLValue { .uuid(self) }

    public init(sqlValue: SQLValue) throws {
        guard case let .uuid(value) = sqlValue else {
            throw SQLValueConversionError.typeMismatch(expected: .uuid, actual: sqlValue)
        }
        self = value
    }
}

extension Optional: SQLValueConvertible where Wrapped: SQLValueConvertible {
    public static var columnType: ColumnType { Wrapped.columnType }
    public static var isNullable: Bool { true }

    public var sqlValue: SQLValue {
        switch self {
        case let .some(value): value.sqlValue
        case .none: .null
        }
    }

    public init(sqlValue: SQLValue) throws {
        if case .null = sqlValue {
            self = .none
        } else {
            self = try .some(Wrapped(sqlValue: sqlValue))
        }
    }
}
