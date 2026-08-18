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

/// SELECT facts that can affect a backend's pagination grammar.
public struct SQLPaginationContext: Sendable, Hashable {
    public let hasOrderings: Bool

    public init(hasOrderings: Bool) {
        self.hasOrderings = hasOrderings
    }
}

/// Where a dialect's pagination clause belongs in a SELECT statement.
public enum SQLPaginationPlacement: Sendable, Hashable {
    /// Immediately after `SELECT`, for grammars such as `TOP (...)`.
    case afterSelect
    /// After predicates and ordering, for grammars such as `LIMIT` or `OFFSET ... FETCH`.
    case suffix
}

/// One lexical fragment of a pagination clause.
public enum SQLPaginationFragment: Sendable, Hashable {
    /// Backend-owned SQL emitted verbatim.
    case literal(String)
    /// An integer emitted as a bound placeholder at this exact lexical position.
    case parameter(Int)
}

/// A backend-specific pagination clause that the renderer emits at its lexical position.
public struct SQLPaginationPlan: Sendable, Hashable {
    public let placement: SQLPaginationPlacement
    public let fragments: [SQLPaginationFragment]

    public init(
        placement: SQLPaginationPlacement,
        fragments: [SQLPaginationFragment]
    ) {
        self.placement = placement
        self.fragments = fragments
    }
}

/// Where a dialect emits a row-returning clause for a DML statement.
public enum SQLDMLReturningPlacement: Sendable, Hashable {
    /// At the statement-specific embedded position used by grammars such as SQL Server `OUTPUT`.
    case embedded
    /// At the statement tail, as in PostgreSQL `RETURNING`.
    case suffix
}

/// One lexical fragment of a dialect-owned DML row-returning clause.
public enum SQLDMLReturningFragment: Sendable, Hashable {
    /// Backend-owned SQL emitted verbatim.
    case literal(String)
    /// One requested column, quoted by the renderer's dialect.
    case column(String)
}

/// A backend-specific DML row-returning clause.
public struct SQLDMLReturningPlan: Sendable, Hashable {
    public let placement: SQLDMLReturningPlacement
    public let fragments: [SQLDMLReturningFragment]

    public init(
        placement: SQLDMLReturningPlacement,
        fragments: [SQLDMLReturningFragment]
    ) {
        self.placement = placement
        self.fragments = fragments
    }
}

/// The rendering policy supplied by a concrete backend adapter.
public protocol SQLDialect: Sendable {
    var capabilities: DialectCapabilities { get }

    func placeholder(at position: Int) -> String
    func quoteIdentifier(_ identifier: String) -> String
    func paginationPlan(
        limit: Int,
        offset: Int?,
        context: SQLPaginationContext
    ) throws -> SQLPaginationPlan
    func insertReturningPlan(columns: [String]) throws -> SQLDMLReturningPlan?
    func updateReturningPlan(columns: [String]) throws -> SQLDMLReturningPlan?
    func deleteReturningPlan(columns: [String]) throws -> SQLDMLReturningPlan?
}

public extension SQLDialect {
    func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// SQL-standard default. Dialects whose grammar or validation differs override this method.
    func paginationPlan(
        limit: Int,
        offset: Int?,
        context: SQLPaginationContext
    ) throws -> SQLPaginationPlan {
        var fragments: [SQLPaginationFragment] = []
        if let offset {
            fragments.append(contentsOf: [
                .literal("OFFSET "),
                .parameter(offset),
                .literal(" ROWS "),
            ])
        }
        fragments.append(contentsOf: [
            .literal("FETCH FIRST "),
            .parameter(limit),
            .literal(" ROWS ONLY"),
        ])
        return SQLPaginationPlan(placement: .suffix, fragments: fragments)
    }

    /// The standard default does not assume a backend-specific row-returning grammar.
    func insertReturningPlan(columns: [String]) throws -> SQLDMLReturningPlan? {
        nil
    }

    /// The standard default does not assume a backend-specific row-returning grammar.
    func updateReturningPlan(columns: [String]) throws -> SQLDMLReturningPlan? {
        nil
    }

    /// The standard default does not assume a backend-specific row-returning grammar.
    func deleteReturningPlan(columns: [String]) throws -> SQLDMLReturningPlan? {
        nil
    }
}
