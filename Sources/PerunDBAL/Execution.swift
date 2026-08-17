import Foundation

/// A backend-neutral row. Decoding is driven by the requested Swift type.
public protocol Row: Sendable {
    func decode<T: SQLValueConvertible>(_ column: String, as type: T.Type) throws -> T
    func decodeIfPresent<T: SQLValueConvertible>(_ column: String, as type: T.Type) throws -> T?
}

/// The normalized outcome of one SQL statement.
public struct ExecResult: Sendable {
    public let rows: [any Row]
    public let rowsAffected: Int?
    /// SQLite's connection-local rowid hint, exposed only for a proven generated-rowid insert.
    /// It is not necessarily a mapped primary key.
    public let lastInsertRowID: Int64?

    public init(
        rows: [any Row] = [],
        rowsAffected: Int? = nil,
        lastInsertRowID: Int64? = nil
    ) {
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.lastInsertRowID = lastInsertRowID
    }
}

/// Semantic information known by the caller but intentionally not inferred from raw SQL.
public enum ExecutionIntent: Sendable, Hashable {
    /// No statement semantics are asserted; backend-specific out-of-band hints stay hidden.
    case arbitrary
    /// The caller proves that this single-row INSERT generates a backend rowid.
    case generatedRowIDInsert
}

/// Something capable of executing already-rendered positional SQL.
public protocol SQLExecutor: Sendable {
    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult
}

public extension SQLExecutor {
    func execute(_ sql: String, _ parameters: [SQLValue]) async throws -> ExecResult {
        try await execute(sql, parameters, intent: .arbitrary)
    }
}

/// A closure-scoped executor. It intentionally cannot create nested transactions.
public protocol Transaction: SQLExecutor {}

/// A logical database façade, normally backed by a connection pool.
public protocol Database: SQLExecutor {
    var dialect: any SQLDialect { get }

    func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T

    /// Releases the underlying pool/client. The composition root owns this lifecycle.
    func shutdown() async
}

public struct DialectCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let returning = Self(rawValue: 1 << 0)
    public static let lastInsertRowID = Self(rawValue: 1 << 1)
    public static let nativeBoolean = Self(rawValue: 1 << 2)
    public static let nativeTimestamp = Self(rawValue: 1 << 3)
    public static let nativeUUID = Self(rawValue: 1 << 4)
}

/// The rendering policy supplied by a concrete backend adapter.
public protocol SQLDialect: Sendable {
    var capabilities: DialectCapabilities { get }

    func placeholder(at position: Int) -> String
    func quoteIdentifier(_ identifier: String) -> String
}

public extension SQLDialect {
    func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
