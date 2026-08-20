import Foundation

/// A backend-neutral row. Decoding is driven by the requested Swift type.
public protocol Row: Sendable {
    /// Decodes `column` through its requested portable Swift type.
    ///
    /// SQL `NULL` is passed to `T` and therefore succeeds only for a type such as `Optional`
    /// that accepts ``SQLValue/null``. Missing columns and incompatible values throw.
    func decode<T: SQLValueConvertible>(_ column: String, as type: T.Type) throws -> T

    /// Returns `nil` for SQL `NULL`; otherwise decodes `column` as `T`.
    ///
    /// Missing columns and incompatible non-null values throw.
    func decodeIfPresent<T: SQLValueConvertible>(_ column: String, as type: T.Type) throws -> T?
}

/// The normalized outcome of one SQL statement.
public struct ExecResult: Sendable {
    /// Rows produced by a query or a DML row-returning clause, in backend order.
    public let rows: [any Row]
    /// The affected-row count, or `nil` when the backend cannot report it reliably.
    public let rowsAffected: Int?
    /// SQLite's connection-local rowid hint, exposed only for a proven generated-rowid insert.
    /// It is not necessarily a mapped primary key.
    public let lastInsertRowID: Int64?

    /// Creates a normalized execution result.
    ///
    /// Custom executors are responsible for preserving the field invariants documented above.
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
    /// Executes one caller-rendered statement with parameters in placeholder order.
    ///
    /// `intent` is a trusted semantic assertion made by the caller. Implementations must not
    /// infer a stronger intent by parsing arbitrary SQL.
    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult
}

public extension SQLExecutor {
    /// Executes arbitrary positional SQL without exposing backend-specific result hints.
    func execute(_ sql: String, _ parameters: [SQLValue]) async throws -> ExecResult {
        try await execute(sql, parameters, intent: .arbitrary)
    }
}

/// A closure-scoped executor valid only during the database-owned transaction body that
/// supplied it.
///
/// A transaction must reject or otherwise safely fail operations attempted after that body
/// returns. It intentionally cannot create nested transactions.
public protocol Transaction: SQLExecutor {}

/// A logical database façade, normally backed by a connection pool.
public protocol Database: SQLExecutor {
    /// The rendering policy paired with this executor.
    ///
    /// Callers must render statements with this dialect rather than combining an executor with
    /// an independently selected backend dialect.
    var dialect: any SQLDialect { get }

    /// Runs `body` on one transaction-scoped executor.
    ///
    /// Route every database operation in `body` through the supplied ``Transaction``. Re-entering
    /// this database from the closure does not join the active transaction: a pooled implementation
    /// may execute that work on another connection or block while waiting for one.
    ///
    /// Returning normally commits. If `body` throws, including an observed cancellation error,
    /// the implementation rolls back and rethrows. The supplied ``Transaction`` must not escape
    /// the closure for later use, and this method does not permit nested transactions.
    func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T

    /// Releases the underlying pool/client. The composition root owns this lifecycle.
    ///
    /// Implementations must make repeated calls safe. New work after shutdown fails with the
    /// underlying client's typed shutdown error.
    func shutdown() async
}

/// An application-defined identifier for mutually exclusive database work.
///
/// Equal raw values identify the same resource within one logical database. Backends may
/// serialize different keys more strongly when they cannot provide independent lock namespaces.
public struct DatabaseLockKey: Sendable, Hashable {
    /// The backend-neutral signed 64-bit lock identifier.
    public let rawValue: Int64

    /// Creates a lock key from its stable application-defined value.
    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }
}

/// A database that can hold an exclusive lock for the complete lifetime of a transaction.
///
/// For one logical database, calls using equal lock keys must not execute their bodies
/// concurrently. An implementation may serialize more keys, but never fewer. It must acquire the
/// lock before invoking `body`, hold it through commit or rollback, and release it as part of that
/// transaction's cleanup. Reads through the protected transaction must not use a database snapshot
/// established before successful lock acquisition; they must be able to observe commits from
/// equal-key calls completed before that acquisition. The supplied executor has the same
/// closure-scoped lifetime as the one in ``Database/withTransaction(_:)``. The enclosing database
/// owns the exclusive transaction boundary: `body` must not submit `BEGIN`, `COMMIT`, `ROLLBACK`,
/// savepoint commands, or any other transaction-control SQL through that executor. Doing so
/// violates this protocol contract, and implementations are not required to recover that
/// transaction.
///
/// There is intentionally no fallback through ordinary ``Database/withTransaction(_:)`` because
/// that protocol does not promise mutual exclusion across connections or façade instances.
public protocol ExclusiveTransactionDatabase: Database {
    /// Runs `body` in a transaction protected by `lockKey`.
    ///
    /// A normal return from this method means its transaction committed. If `body` throws, the
    /// implementation rolls back and rethrows. Cancellation observed before commit begins also
    /// rolls back and throws. An implementation may still reject the transaction after `body`
    /// returns; commit failure or cancellation once commit begins may leave its outcome
    /// indeterminate, but a known rollback must never be reported as success. The supplied
    /// ``Transaction`` must not escape the closure, create a nested transaction, or submit
    /// transaction-control SQL.
    func withExclusiveTransaction<T: Sendable>(
        lockKey: DatabaseLockKey,
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T
}

/// Features that a paired dialect and executor can provide without unsafe emulation.
public struct DialectCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// DML statements can return requested rows through a dialect-provided clause.
    public static let returning = Self(rawValue: 1 << 0)
    /// Proven generated-rowid inserts can expose ``ExecResult/lastInsertRowID``.
    public static let lastInsertRowID = Self(rawValue: 1 << 1)
    /// The backend has a native boolean type.
    public static let nativeBoolean = Self(rawValue: 1 << 2)
    /// The backend has a native timestamp type matching the portable timestamp semantics.
    public static let nativeTimestamp = Self(rawValue: 1 << 3)
    /// The backend has a native UUID type.
    public static let nativeUUID = Self(rawValue: 1 << 4)
}

/// SELECT facts that can affect a backend's pagination grammar.
public struct SQLPaginationContext: Sendable, Hashable {
    /// Whether the rendered SELECT already contains at least one ordering.
    public let hasOrderings: Bool

    /// Creates pagination context for the SELECT currently being rendered.
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
    /// The lexical location at which the renderer inserts `fragments`.
    public let placement: SQLPaginationPlacement
    /// Ordered trusted literals and bound integer parameters.
    public let fragments: [SQLPaginationFragment]

    /// Creates a pagination plan from ordered trusted fragments.
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
    /// The statement-specific location at which the renderer inserts `fragments`.
    public let placement: SQLDMLReturningPlacement
    /// Ordered trusted literals and renderer-quoted requested columns.
    public let fragments: [SQLDMLReturningFragment]

    /// Creates a DML row-returning plan from ordered trusted fragments.
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
    /// Features supported jointly by this dialect and its paired executor.
    var capabilities: DialectCapabilities { get }

    /// Returns the backend placeholder for a one-based bind position.
    ///
    /// - Precondition: `position` is greater than zero.
    func placeholder(at position: Int) -> String

    /// Quotes one complete identifier according to the backend grammar.
    func quoteIdentifier(_ identifier: String) -> String

    /// Returns the backend column type spelling for a portable type.
    func renderColumnType(_ type: ColumnType) -> String

    /// Returns the complete quoted column phrase for a generated `Int64` primary key.
    func renderGeneratedPrimaryKeyColumn(_ name: String) -> String

    /// Plans a validated pagination clause and its lexical placement.
    ///
    /// The renderer supplies a nonnegative `limit` and either `nil` or a nonnegative `offset`.
    func paginationPlan(
        limit: Int,
        offset: Int?,
        context: SQLPaginationContext
    ) throws -> SQLPaginationPlan
    /// Plans an INSERT row-returning clause for nonempty, validated column names.
    func insertReturningPlan(columns: [String]) throws -> SQLDMLReturningPlan?
    /// Plans an UPDATE row-returning clause for nonempty, validated column names.
    func updateReturningPlan(columns: [String]) throws -> SQLDMLReturningPlan?
    /// Plans a DELETE row-returning clause for nonempty, validated column names.
    func deleteReturningPlan(columns: [String]) throws -> SQLDMLReturningPlan?
}

public extension SQLDialect {
    func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// SQL-standard-oriented defaults. Concrete adapters override non-standard spellings.
    func renderColumnType(_ type: ColumnType) -> String {
        switch type {
        case .boolean: "BOOLEAN"
        case .int32: "INTEGER"
        case .int64: "BIGINT"
        case .double: "DOUBLE PRECISION"
        case .text: "TEXT"
        case .blob: "BLOB"
        case .timestamp: "TIMESTAMP WITH TIME ZONE"
        case .uuid: "UUID"
        }
    }

    /// SQL-standard identity default. Dialects may replace the entire column phrase.
    func renderGeneratedPrimaryKeyColumn(_ name: String) -> String {
        "\(quoteIdentifier(name)) \(renderColumnType(.int64)) "
            + "GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY"
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
