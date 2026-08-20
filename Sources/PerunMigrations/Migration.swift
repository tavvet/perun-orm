import PerunDBAL

/// The transaction-scoped execution surface supplied to one migration body.
///
/// A context is created and owned by ``Migrator``. Callers receive it only while a migration is
/// running and must not retain it or start work that outlives the migration body.
public struct MigrationContext: SQLExecutor {
    /// The rendering policy paired with the active migration transaction.
    public let dialect: any SQLDialect

    private let executeOperation: @Sendable (
        String,
        [SQLValue],
        ExecutionIntent
    ) async throws -> ExecResult

    init(
        dialect: any SQLDialect,
        execute: @escaping @Sendable (
            String,
            [SQLValue],
            ExecutionIntent
        ) async throws -> ExecResult
    ) {
        self.dialect = dialect
        executeOperation = execute
    }

    /// A renderer configured with ``dialect``.
    public var renderer: SQLRenderer {
        SQLRenderer(dialect: dialect)
    }

    /// Executes one positional statement inside the active migration transaction.
    public func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await executeOperation(sql, parameters, intent)
    }
}

/// One ordered, forward-only database migration.
///
/// Creating a value does not validate its identifier or revision.
/// ``Migrator/init(database:migrations:trackingTableName:)`` validates the complete plan,
/// including duplicate identifiers, before any database operation.
public struct Migration: Sendable {
    /// The stable identifier persisted in migration history.
    public let id: String
    /// The positive revision used to detect changes to a planned migration.
    public let revision: Int64

    private let applyOperation: @Sendable (MigrationContext) async throws -> Void

    /// Creates a migration and its transaction-scoped body.
    ///
    /// - Parameters:
    ///   - id: A stable identifier. Plan validation accepts
    ///     `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`.
    ///   - revision: A positive explicit revision. The default is `1`.
    ///   - apply: The work to execute when this migration is pending.
    public init(
        id: String,
        revision: Int64 = 1,
        _ apply: @escaping @Sendable (MigrationContext) async throws -> Void
    ) {
        self.id = id
        self.revision = revision
        applyOperation = apply
    }

    func apply(to context: MigrationContext) async throws {
        try await applyOperation(context)
    }
}
