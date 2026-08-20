import Foundation
import PerunDBAL

/// Lifecycle and concurrency violations at the session or unit-of-work boundary.
public enum SessionError: Error, Sendable, Equatable {
    /// A unit of work starts during direct session I/O or another unit of work, or direct I/O is
    /// attempted during a unit of work.
    case sessionBusy
    /// A second unit-of-work operation overlaps an operation already in flight.
    case unitOfWorkBusy
    /// An escaped unit of work is used after its closure has finished.
    case unitOfWorkClosed
    /// A prior operation made the transaction unsafe to commit, including an executor or
    /// post-write failure or rejected transaction-control SQL.
    case unitOfWorkRollbackOnly
    /// Caller-owned raw SQL attempted to control the transaction owned by the unit of work.
    case transactionControlNotAllowed(command: String)
}

/// ORM-level invariant failures detected after schema validation or row execution.
public enum ORMError: Error, Sendable, Equatable {
    /// A cached identity entry cannot be materialized as the requested entity type.
    case identityMapTypeMismatch(table: String, primaryKey: SQLValue)
    /// A primary-key lookup returned more than one row.
    case multipleRowsForPrimaryKey(table: String, primaryKey: SQLValue)
    /// A hydrated row carries a primary key different from the requested or written key.
    case hydratedPrimaryKeyMismatch(table: String, expected: SQLValue, actual: SQLValue)
    /// An update or delete snapshot is detached from this session.
    case entityNotManaged(table: String, primaryKey: SQLValue)
    /// An update attempted to change the entity primary key.
    case primaryKeyChanged(table: String, expected: SQLValue, actual: SQLValue)
    /// An update or delete used an older managed snapshot.
    case staleEntitySnapshot(table: String, primaryKey: SQLValue)
    /// A row required by an eager write disappeared before it could be reloaded.
    case entityNotFound(table: String, primaryKey: SQLValue)
    /// An UPDATE affected a number of rows incompatible with one primary key.
    case unexpectedUpdateAffectedRowCount(
        table: String,
        primaryKey: SQLValue,
        actual: Int
    )
    /// An UPDATE row-returning clause produced a number of rows other than one.
    case unexpectedUpdateResultRowCount(
        table: String,
        primaryKey: SQLValue,
        actual: Int
    )
    /// A DELETE affected a number of rows incompatible with one primary key.
    case unexpectedDeleteAffectedRowCount(
        table: String,
        primaryKey: SQLValue,
        actual: Int
    )
    /// The selected dialect cannot recover this generated primary key safely.
    case generatedPrimaryKeyRetrievalUnsupported(table: String)
    /// An INSERT reported an affected-row count other than one.
    case unexpectedInsertAffectedRowCount(table: String, actual: Int?)
    /// An INSERT row-returning clause produced a number of rows other than one.
    case unexpectedInsertResultRowCount(table: String, actual: Int)
    /// A proven SQLite generated-rowid insert did not report its row ID.
    case generatedPrimaryKeyUnavailable(table: String)
    /// Reloading an inserted row by primary key produced an unexpected row count.
    case insertedRowLookupCount(table: String, primaryKey: SQLValue, actual: Int)
    /// A count query did not return exactly one aggregate row.
    case unexpectedCountResultRowCount(table: String, actual: Int)
}

/// Actor-isolated ORM state. Database operations inside a transaction are exposed only by UoW.
public actor Session {
    private let database: any Database
    var schemaCache = EntitySchemaCache()
    var identityMap = SessionIdentityMap()
    var activeUnitOfWork: UUID?
    private var activeDatabaseOperations = 0

    /// Creates a request- or command-scoped session over an application-owned database.
    ///
    /// The session owns an identity map and a validated-schema cache for its complete lifetime.
    /// Do not use one session as an application-wide singleton: create a fresh session for each
    /// independent request or command. The session does not shut the database down.
    public init(database: any Database) {
        self.database = database
    }

    /// Raw positional SQL escape hatch outside a unit of work.
    /// Its unknown effect invalidates managed snapshots before and after execution.
    public func execute(_ sql: String, _ parameters: [SQLValue] = []) async throws -> ExecResult {
        try beginDirectDatabaseOperation()
        defer { endDirectDatabaseOperation() }
        invalidateIdentity()
        defer { invalidateIdentity() }
        return try await database.execute(sql, parameters)
    }

    /// Returns the session snapshot for a primary key, hydrating and caching it on a miss.
    public func find<E: Entity>(_ type: E.Type, _ primaryKey: E.PK) async throws -> E? {
        try beginDirectDatabaseOperation()
        defer { endDirectDatabaseOperation() }

        let schema = try validatedSchema(for: type)
        let primaryKeyValue = primaryKey.sqlValue
        let key = EntityKey(type: ObjectIdentifier(type), primaryKey: primaryKeyValue)
        if let cached = identityMap[key] {
            guard cached.entityType == ObjectIdentifier(type) else {
                throw ORMError.identityMapTypeMismatch(
                    table: schema.tableName,
                    primaryKey: primaryKeyValue
                )
            }
            return try schema.materialize(from: cached.mappedValues)
        }

        let revision = identityMap.revision
        let rendered = try SQLRenderer(dialect: database.dialect).render(
            schema.findStatement(primaryKey: primaryKey)
        )
        let result = try await database.execute(rendered.sql, rendered.parameters)
        guard result.rows.count <= 1 else {
            throw ORMError.multipleRowsForPrimaryKey(
                table: schema.tableName,
                primaryKey: primaryKeyValue
            )
        }
        guard let row = result.rows.first else { return nil }

        let entity = try E(row: row)
        let snapshot = managedSnapshot(of: entity, schema: schema)
        let hydratedPrimaryKey = snapshot.primaryKey
        guard hydratedPrimaryKey == primaryKeyValue else {
            throw ORMError.hydratedPrimaryKeyMismatch(
                table: schema.tableName,
                expected: primaryKeyValue,
                actual: hydratedPrimaryKey
            )
        }
        if identityMap.revision == revision {
            identityMap[key] = snapshot
        }
        return entity
    }

    /// Executes a typed SELECT and refreshes every returned identity snapshot atomically.
    public func fetch<E: Entity>(_ query: Query<E>) async throws -> [E] {
        try beginDirectDatabaseOperation()
        defer { endDirectDatabaseOperation() }

        let schema = try validatedSchema(for: E.self)
        let rendered = try SQLRenderer(dialect: database.dialect).render(query.statement)
        let revision = identityMap.revision
        let result = try await database.execute(rendered.sql, rendered.parameters)
        let batch = try hydrate(result.rows, schema: schema)
        if identityMap.revision == revision {
            for (key, snapshot) in batch.snapshots {
                identityMap[key] = snapshot
            }
        }
        return batch.entities
    }

    /// Executes caller-owned SQL and atomically hydrates its rows as detached entities.
    /// Raw SQL has an unknown effect, so no returned row becomes a managed snapshot.
    public func fetch<E: Entity>(
        _ type: E.Type,
        sql: String,
        params: [SQLValue] = []
    ) async throws -> [E] {
        try beginDirectDatabaseOperation()
        defer { endDirectDatabaseOperation() }

        let schema = try validatedSchema(for: type)
        invalidateIdentity()
        defer { invalidateIdentity() }
        let result = try await database.execute(sql, params)
        let batch = try hydrate(result.rows, schema: schema)
        return batch.entities
    }

    /// Executes at most one row of a typed SELECT and refreshes its identity snapshot.
    public func first<E: Entity>(_ query: Query<E>) async throws -> E? {
        try await fetch(query.firstQuery).first
    }

    /// Counts every row matching the typed predicate, before ordering or pagination.
    public func count<E: Entity>(_ query: Query<E>) async throws -> Int64 {
        try beginDirectDatabaseOperation()
        defer { endDirectDatabaseOperation() }

        let schema = try validatedSchema(for: E.self)
        let rendered = try SQLRenderer(dialect: database.dialect).render(query.countStatement)
        let result = try await database.execute(rendered.sql, rendered.parameters)
        return try decodeCount(result, table: schema.tableName)
    }

    /// Runs eager ORM operations in one database transaction.
    ///
    /// While the closure is active, perform database work only through its ``UnitOfWork``.
    /// Returning normally commits and promotes staged snapshots into the session identity map;
    /// throwing rolls back and discards them. A transaction executor failure makes the unit of
    /// work rollback-only even when the closure catches that original error.
    ///
    /// - Throws: ``SessionError/sessionBusy`` if direct session I/O or another unit of work is
    ///   already active.
    public func withUnitOfWork<T: Sendable>(
        _ body: @Sendable (UnitOfWork) async throws -> T
    ) async throws -> T {
        guard activeUnitOfWork == nil, activeDatabaseOperations == 0 else {
            throw SessionError.sessionBusy
        }

        let token = UUID()
        let dialect = database.dialect
        activeUnitOfWork = token
        defer {
            precondition(activeUnitOfWork == token)
            activeUnitOfWork = nil
        }

        let outcome = try await database.withTransaction { transaction in
            let unitOfWork = UnitOfWork(
                transaction: transaction,
                dialect: dialect,
                session: self,
                token: token
            )
            do {
                let value = try await body(unitOfWork)
                let changes = try await unitOfWork.close()
                return UnitOfWorkOutcome(value: value, changes: changes)
            } catch {
                _ = try? await unitOfWork.close()
                throw error
            }
        }

        identityMap.apply(outcome.changes)
        return outcome.value
    }

    private func beginDirectDatabaseOperation() throws {
        guard activeUnitOfWork == nil else {
            throw SessionError.sessionBusy
        }
        activeDatabaseOperations += 1
    }

    private func endDirectDatabaseOperation() {
        precondition(activeDatabaseOperations > 0)
        activeDatabaseOperations -= 1
    }

    func invalidateIdentity() {
        identityMap.invalidate()
    }
}
