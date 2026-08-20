import PerunDBAL

/// Deterministic failures enforced by the migration execution boundary.
public enum MigrationExecutionError: Error, Sendable, Equatable {
    /// Another operation is already using this migration context.
    case contextBusy
    /// The migration body has returned and the context no longer accepts work.
    case contextClosed
    /// The migration body returned while an operation was still running.
    case contextOperationEscaped
    /// A caught execution-boundary failure requires the outer transaction to roll back.
    case contextRollbackOnly
    /// A migration attempted to manage the database-owned transaction.
    case transactionControlNotAllowed(command: String)
}

/// The transaction-scoped execution surface supplied to one migration body.
///
/// A context is created and owned by ``Migrator``. Callers receive it only while a migration is
/// running and must not retain it or start work that outlives the migration body.
public struct MigrationContext: SQLExecutor {
    /// The rendering policy paired with the active migration transaction.
    public let dialect: any SQLDialect

    private let state: MigrationContextState

    init(
        dialect: any SQLDialect,
        execute: @escaping @Sendable (
            String,
            [SQLValue],
            ExecutionIntent
        ) async throws -> ExecResult
    ) {
        self.dialect = dialect
        state = MigrationContextState(execute: execute)
    }

    init(dialect: any SQLDialect, transaction: any Transaction) {
        self.init(dialect: dialect) { sql, parameters, intent in
            try await transaction.execute(sql, parameters, intent: intent)
        }
    }

    /// A renderer configured with ``dialect``.
    public var renderer: SQLRenderer {
        SQLRenderer(dialect: dialect)
    }

    /// Executes one positional statement inside the active migration transaction.
    ///
    /// A leading transaction-control command is rejected before the transaction executor is
    /// called. Every other input is passed to that executor, including ordinary SQL batches that
    /// it must atomically reject under the `SQLExecutor` single-statement contract.
    public func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await state.execute(sql, parameters, intent: intent)
    }

    /// Closes the shared context lifecycle after its migration body returns.
    func close() async throws {
        try await state.close()
    }
}

private actor MigrationContextState {
    private enum Lifecycle {
        case open
        case closing
        case closed
    }

    private typealias ExecuteOperation = @Sendable (
        String,
        [SQLValue],
        ExecutionIntent
    ) async throws -> ExecResult

    private var lifecycle = Lifecycle.open
    private var executeOperation: ExecuteOperation?
    private var inFlightOperations = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var rollbackOnly = false
    private var terminalCloseError: MigrationExecutionError?

    init(
        execute: @escaping @Sendable (
            String,
            [SQLValue],
            ExecutionIntent
        ) async throws -> ExecResult
    ) {
        executeOperation = execute
    }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try beginOperation()
        defer { endOperation() }

        do {
            try Task.checkCancellation()

            if let command = sqlTransactionControlCommand(in: sql) {
                throw MigrationExecutionError.transactionControlNotAllowed(command: command)
            }

            guard let executeOperation else {
                throw MigrationExecutionError.contextClosed
            }
            return try await executeOperation(sql, parameters, intent)
        } catch {
            rollbackOnly = true
            throw error
        }
    }

    func close() async throws {
        switch lifecycle {
        case .open:
            lifecycle = .closing
            if inFlightOperations == 0 {
                finishClosing()
            } else {
                rollbackOnly = true
                terminalCloseError = .contextOperationEscaped
            }
        case .closing:
            break
        case .closed:
            try validateClosedState()
            return
        }

        if lifecycle != .closed {
            await withCheckedContinuation { continuation in
                if lifecycle == .closed {
                    continuation.resume()
                } else {
                    closeWaiters.append(continuation)
                }
            }
        }

        try validateClosedState()
    }

    private func beginOperation() throws {
        guard lifecycle == .open else {
            throw MigrationExecutionError.contextClosed
        }
        guard !rollbackOnly else {
            throw MigrationExecutionError.contextRollbackOnly
        }
        guard inFlightOperations == 0 else {
            rollbackOnly = true
            throw MigrationExecutionError.contextBusy
        }
        inFlightOperations = 1
    }

    private func endOperation() {
        precondition(inFlightOperations == 1)
        inFlightOperations = 0
        if lifecycle == .closing {
            finishClosing()
        }
    }

    private func finishClosing() {
        precondition(lifecycle == .closing)
        precondition(inFlightOperations == 0)

        lifecycle = .closed
        executeOperation = nil
        let waiters = closeWaiters
        closeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func validateClosedState() throws {
        if let terminalCloseError {
            throw terminalCloseError
        }
        if rollbackOnly {
            throw MigrationExecutionError.contextRollbackOnly
        }
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
