import Foundation
import PerunDBAL

public enum SessionError: Error, Sendable, Equatable {
    case sessionBusy
    case unitOfWorkBusy
    case unitOfWorkClosed
    case unitOfWorkRollbackOnly
    case transactionControlNotAllowed(command: String)
}

/// ORM-level invariant failures detected after schema validation or row execution.
public enum ORMError: Error, Sendable, Equatable {
    case identityMapTypeMismatch(table: String, primaryKey: SQLValue)
    case multipleRowsForPrimaryKey(table: String, primaryKey: SQLValue)
    case hydratedPrimaryKeyMismatch(table: String, expected: SQLValue, actual: SQLValue)
    case entityNotManaged(table: String, primaryKey: SQLValue)
    case primaryKeyChanged(table: String, expected: SQLValue, actual: SQLValue)
    case staleEntitySnapshot(table: String, primaryKey: SQLValue)
    case entityNotFound(table: String, primaryKey: SQLValue)
    case unexpectedUpdateAffectedRowCount(
        table: String,
        primaryKey: SQLValue,
        actual: Int
    )
    case unexpectedUpdateResultRowCount(
        table: String,
        primaryKey: SQLValue,
        actual: Int
    )
    case unexpectedDeleteAffectedRowCount(
        table: String,
        primaryKey: SQLValue,
        actual: Int
    )
    case generatedPrimaryKeyRetrievalUnsupported(table: String)
    case unexpectedInsertAffectedRowCount(table: String, actual: Int?)
    case unexpectedInsertResultRowCount(table: String, actual: Int)
    case generatedPrimaryKeyUnavailable(table: String)
    case insertedRowLookupCount(table: String, primaryKey: SQLValue, actual: Int)
    case unexpectedCountResultRowCount(table: String, actual: Int)
}

fileprivate struct EntityKey: Sendable, Hashable {
    let type: ObjectIdentifier
    let primaryKey: SQLValue
}

fileprivate struct EntityFindPlan<E: Entity>: Sendable {
    let tableName: String
    let statement: SQLSelect
    let cachedEntity: E?
    let isDeleted: Bool
}

fileprivate struct EntityFetchPlan: Sendable {
    let statement: SQLSelect
}

fileprivate struct EntityCountPlan: Sendable {
    let tableName: String
    let statement: SQLCount
}

fileprivate struct ManagedEntitySnapshot: Sendable {
    let entityType: ObjectIdentifier
    let mappedValues: [SQLValue]
    let primaryKey: SQLValue
}

fileprivate enum ManagedEntityState: Sendable {
    case snapshot(ManagedEntitySnapshot)
    case deleted
}

fileprivate struct EntityFetchBatch<E: Entity>: Sendable {
    let entities: [E]
    let snapshots: [EntityKey: ManagedEntitySnapshot]
}

fileprivate struct EntityInsertPlan: Sendable {
    let tableName: String
    let statement: SQLInsert
    let primaryKey: SQLValue
    let primaryKeyIsGenerated: Bool
    let snapshot: ManagedEntitySnapshot
}

fileprivate struct EntityUpdatePlan: Sendable {
    let tableName: String
    let statement: SQLUpdate?
    let primaryKey: SQLValue
    let snapshot: ManagedEntitySnapshot
}

fileprivate struct EntityDeletePlan: Sendable {
    let tableName: String
    let statement: SQLDelete
    let primaryKey: SQLValue
}

fileprivate struct UnitOfWorkChanges: Sendable {
    let invalidatesIdentity: Bool
    let entities: [EntityKey: ManagedEntityState]
}

private struct UnitOfWorkOutcome<Value: Sendable>: Sendable {
    let value: Value
    let changes: UnitOfWorkChanges
}

/// Actor-isolated ORM state. Database operations inside a transaction are exposed only by UoW.
public actor Session {
    private let database: any Database
    private var validatedSchemas: [ObjectIdentifier: Any] = [:]
    private var identity: [EntityKey: ManagedEntitySnapshot] = [:]
    private var activeUnitOfWork: UUID?
    private var activeDatabaseOperations = 0

    public init(database: any Database) {
        self.database = database
    }

    /// Raw positional SQL escape hatch outside a unit of work.
    public func execute(_ sql: String, _ parameters: [SQLValue] = []) async throws -> ExecResult {
        try beginDirectDatabaseOperation()
        defer { endDirectDatabaseOperation() }
        return try await database.execute(sql, parameters)
    }

    /// Returns the session snapshot for a primary key, hydrating and caching it on a miss.
    public func find<E: Entity>(_ type: E.Type, _ primaryKey: E.PK) async throws -> E? {
        try beginDirectDatabaseOperation()
        defer { endDirectDatabaseOperation() }

        let schema = try validatedSchema(for: type)
        let primaryKeyValue = primaryKey.sqlValue
        let key = EntityKey(type: ObjectIdentifier(type), primaryKey: primaryKeyValue)
        if let cached = identity[key] {
            guard cached.entityType == ObjectIdentifier(type) else {
                throw ORMError.identityMapTypeMismatch(
                    table: schema.tableName,
                    primaryKey: primaryKeyValue
                )
            }
            return try schema.materialize(from: cached.mappedValues)
        }

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
        identity[key] = snapshot
        return entity
    }

    /// Executes a typed SELECT and refreshes every returned identity snapshot atomically.
    public func fetch<E: Entity>(_ query: Query<E>) async throws -> [E] {
        try beginDirectDatabaseOperation()
        defer { endDirectDatabaseOperation() }

        let schema = try validatedSchema(for: E.self)
        let rendered = try SQLRenderer(dialect: database.dialect).render(query.statement)
        let result = try await database.execute(rendered.sql, rendered.parameters)
        let batch = try hydrate(result.rows, schema: schema)
        for (key, snapshot) in batch.snapshots {
            identity[key] = snapshot
        }
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

        if outcome.changes.invalidatesIdentity {
            identity.removeAll(keepingCapacity: true)
        }
        for (key, state) in outcome.changes.entities {
            switch state {
            case let .snapshot(snapshot):
                identity[key] = snapshot
            case .deleted:
                identity.removeValue(forKey: key)
            }
        }
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

    private func validatedSchema<E: Entity>(for type: E.Type) throws -> EntitySchema<E> {
        let key = ObjectIdentifier(type)
        if let cached = validatedSchemas[key] {
            guard let schema = cached as? EntitySchema<E> else {
                preconditionFailure("entity type key resolved to a different validated schema")
            }
            return schema
        }

        let schema = try EntitySchema(type)
        validatedSchemas[key] = schema
        return schema
    }

    fileprivate func unitOfWorkFindPlan<E: Entity>(
        for type: E.Type,
        primaryKey: E.PK,
        overlayState: ManagedEntityState?,
        useCachedEntity: Bool,
        token: UUID
    ) throws -> EntityFindPlan<E> {
        try validateUnitOfWork(token)
        let schema = try validatedSchema(for: type)
        let primaryKeyValue = primaryKey.sqlValue
        let key = EntityKey(type: ObjectIdentifier(type), primaryKey: primaryKeyValue)
        let cachedEntity: E?
        let isDeleted: Bool
        let cachedSnapshot: ManagedEntitySnapshot?
        switch overlayState {
        case let .snapshot(snapshot):
            cachedSnapshot = snapshot
            isDeleted = false
        case .deleted:
            cachedSnapshot = nil
            isDeleted = true
        case nil:
            cachedSnapshot = useCachedEntity ? identity[key] : nil
            isDeleted = false
        }
        if let cachedSnapshot {
            guard cachedSnapshot.entityType == ObjectIdentifier(type) else {
                throw ORMError.identityMapTypeMismatch(
                    table: schema.tableName,
                    primaryKey: primaryKeyValue
                )
            }
            cachedEntity = try schema.materialize(from: cachedSnapshot.mappedValues)
        } else {
            cachedEntity = nil
        }
        return EntityFindPlan(
            tableName: schema.tableName,
            statement: schema.findStatement(primaryKey: primaryKey),
            cachedEntity: cachedEntity,
            isDeleted: isDeleted
        )
    }

    fileprivate func unitOfWorkFetchPlan<E: Entity>(
        for query: Query<E>,
        token: UUID
    ) throws -> EntityFetchPlan {
        try validateUnitOfWork(token)
        _ = try validatedSchema(for: E.self)
        return EntityFetchPlan(statement: query.statement)
    }

    fileprivate func unitOfWorkHydrate<E: Entity>(
        _ rows: [any Row],
        as type: E.Type,
        token: UUID
    ) throws -> EntityFetchBatch<E> {
        try validateUnitOfWork(token)
        let schema = try validatedSchema(for: type)
        return try hydrate(rows, schema: schema)
    }

    fileprivate func unitOfWorkCountPlan<E: Entity>(
        for query: Query<E>,
        token: UUID
    ) throws -> EntityCountPlan {
        try validateUnitOfWork(token)
        let schema = try validatedSchema(for: E.self)
        return EntityCountPlan(
            tableName: schema.tableName,
            statement: query.countStatement
        )
    }

    fileprivate func unitOfWorkInsertPlan<E: Entity>(
        for entity: E,
        returning: Bool,
        token: UUID
    ) throws -> EntityInsertPlan {
        try validateUnitOfWork(token)
        let schema = try validatedSchema(for: E.self)
        let snapshot = managedSnapshot(of: entity, schema: schema)
        return EntityInsertPlan(
            tableName: schema.tableName,
            statement: schema.insertStatement(
                mappedValues: snapshot.mappedValues,
                returning: returning
            ),
            primaryKey: snapshot.primaryKey,
            primaryKeyIsGenerated: schema.primaryKeyIsGenerated,
            snapshot: snapshot
        )
    }

    fileprivate func unitOfWorkUpdatePlan<E: Entity>(
        for entity: E,
        from originalSnapshot: ManagedEntitySnapshot,
        overlayState: ManagedEntityState?,
        useCachedEntity: Bool,
        returning: Bool,
        token: UUID
    ) throws -> EntityUpdatePlan {
        try validateUnitOfWork(token)
        let schema = try validatedSchema(for: E.self)
        guard originalSnapshot.entityType == ObjectIdentifier(E.self) else {
            throw ORMError.identityMapTypeMismatch(
                table: schema.tableName,
                primaryKey: originalSnapshot.primaryKey
            )
        }
        let originalValues = originalSnapshot.mappedValues
        let updatedSnapshot = managedSnapshot(of: entity, schema: schema)
        let primaryKey = originalSnapshot.primaryKey
        let updatedPrimaryKey = updatedSnapshot.primaryKey
        guard updatedPrimaryKey == primaryKey else {
            throw ORMError.primaryKeyChanged(
                table: schema.tableName,
                expected: primaryKey,
                actual: updatedPrimaryKey
            )
        }
        let key = EntityKey(type: ObjectIdentifier(E.self), primaryKey: primaryKey)
        let cachedSnapshot: ManagedEntitySnapshot?
        switch overlayState {
        case let .snapshot(snapshot):
            cachedSnapshot = snapshot
        case .deleted:
            cachedSnapshot = nil
        case nil:
            cachedSnapshot = useCachedEntity ? identity[key] : nil
        }
        guard let cachedSnapshot else {
            throw ORMError.entityNotManaged(
                table: schema.tableName,
                primaryKey: primaryKey
            )
        }
        guard cachedSnapshot.entityType == ObjectIdentifier(E.self) else {
            throw ORMError.identityMapTypeMismatch(
                table: schema.tableName,
                primaryKey: primaryKey
            )
        }
        guard schema.hasSameMappedValues(cachedSnapshot.mappedValues, originalValues) else {
            throw ORMError.staleEntitySnapshot(
                table: schema.tableName,
                primaryKey: primaryKey
            )
        }
        return EntityUpdatePlan(
            tableName: schema.tableName,
            statement: schema.updateStatement(
                mappedValues: updatedSnapshot.mappedValues,
                comparedTo: cachedSnapshot.mappedValues,
                returning: returning
            ),
            primaryKey: primaryKey,
            snapshot: updatedSnapshot
        )
    }

    fileprivate func unitOfWorkDeletePlan<E: Entity>(
        for type: E.Type,
        from originalSnapshot: ManagedEntitySnapshot,
        overlayState: ManagedEntityState?,
        useCachedEntity: Bool,
        token: UUID
    ) throws -> EntityDeletePlan {
        try validateUnitOfWork(token)
        let schema = try validatedSchema(for: type)
        guard originalSnapshot.entityType == ObjectIdentifier(type) else {
            throw ORMError.identityMapTypeMismatch(
                table: schema.tableName,
                primaryKey: originalSnapshot.primaryKey
            )
        }
        let primaryKey = originalSnapshot.primaryKey
        let key = EntityKey(type: ObjectIdentifier(type), primaryKey: primaryKey)
        let cachedSnapshot: ManagedEntitySnapshot?
        switch overlayState {
        case let .snapshot(snapshot):
            cachedSnapshot = snapshot
        case .deleted:
            cachedSnapshot = nil
        case nil:
            cachedSnapshot = useCachedEntity ? identity[key] : nil
        }
        guard let cachedSnapshot else {
            throw ORMError.entityNotManaged(
                table: schema.tableName,
                primaryKey: primaryKey
            )
        }
        guard cachedSnapshot.entityType == ObjectIdentifier(type) else {
            throw ORMError.identityMapTypeMismatch(
                table: schema.tableName,
                primaryKey: primaryKey
            )
        }
        guard schema.hasSameMappedValues(
            cachedSnapshot.mappedValues,
            originalSnapshot.mappedValues
        ) else {
            throw ORMError.staleEntitySnapshot(
                table: schema.tableName,
                primaryKey: primaryKey
            )
        }
        return EntityDeletePlan(
            tableName: schema.tableName,
            statement: schema.deleteStatement(primaryKey: primaryKey),
            primaryKey: primaryKey
        )
    }

    fileprivate func unitOfWorkSnapshot<E: Entity>(
        of entity: E,
        token: UUID
    ) throws -> ManagedEntitySnapshot {
        try validateUnitOfWork(token)
        let schema = try validatedSchema(for: E.self)
        return managedSnapshot(of: entity, schema: schema)
    }

    fileprivate func invalidateIdentityForUnitOfWork(token: UUID) {
        precondition(activeUnitOfWork == token)
        identity.removeAll(keepingCapacity: true)
    }

    fileprivate func invalidateIdentityKeyForUnitOfWork(_ key: EntityKey, token: UUID) {
        precondition(activeUnitOfWork == token)
        identity.removeValue(forKey: key)
    }

    private func validateUnitOfWork(_ token: UUID) throws {
        guard activeUnitOfWork == token else {
            throw SessionError.unitOfWorkClosed
        }
    }

    private func managedSnapshot<E: Entity>(
        of entity: E,
        schema: EntitySchema<E>
    ) -> ManagedEntitySnapshot {
        let mappedValues = schema.mappedValues(of: entity)
        return ManagedEntitySnapshot(
            entityType: ObjectIdentifier(E.self),
            mappedValues: mappedValues,
            primaryKey: schema.primaryKeyValue(in: mappedValues)
        )
    }

    private func hydrate<E: Entity>(
        _ rows: [any Row],
        schema: EntitySchema<E>
    ) throws -> EntityFetchBatch<E> {
        var entities: [E] = []
        var snapshots: [EntityKey: ManagedEntitySnapshot] = [:]
        entities.reserveCapacity(rows.count)
        snapshots.reserveCapacity(rows.count)

        for row in rows {
            let entity = try E(row: row)
            let snapshot = managedSnapshot(of: entity, schema: schema)
            let key = EntityKey(
                type: ObjectIdentifier(E.self),
                primaryKey: snapshot.primaryKey
            )
            guard snapshots[key] == nil else {
                throw ORMError.multipleRowsForPrimaryKey(
                    table: schema.tableName,
                    primaryKey: snapshot.primaryKey
                )
            }
            entities.append(entity)
            snapshots[key] = snapshot
        }

        return EntityFetchBatch(entities: entities, snapshots: snapshots)
    }
}

/// The scoped transactional executor. Its snapshots reach the session only after commit.
public actor UnitOfWork {
    private enum Lifecycle: Equatable {
        case open
        case closing
        case closed
    }

    private let transaction: any Transaction
    private let dialect: any SQLDialect
    private let session: Session
    private let token: UUID
    private var lifecycle = Lifecycle.open
    private var inFlightOperations = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var overlay: [EntityKey: ManagedEntityState] = [:]
    private var rollbackOnly = false
    private var invalidatesSessionIdentity = false

    init(
        transaction: any Transaction,
        dialect: any SQLDialect,
        session: Session,
        token: UUID
    ) {
        self.transaction = transaction
        self.dialect = dialect
        self.session = session
        self.token = token
    }

    /// Executes one raw statement. Success invalidates prior ORM snapshots conservatively;
    /// transaction-control statements are rejected and make this unit of work rollback-only.
    public func execute(_ sql: String, _ parameters: [SQLValue] = []) async throws -> ExecResult {
        try beginOperation()
        defer { endOperation() }

        if let command = transactionControlCommand(in: sql) {
            rollbackOnly = true
            throw SessionError.transactionControlNotAllowed(command: command)
        }

        let result = try await executeTransaction(sql, parameters)
        let shouldInvalidateBaseIdentity = !invalidatesSessionIdentity
        invalidatesSessionIdentity = true
        overlay.removeAll(keepingCapacity: true)
        if shouldInvalidateBaseIdentity {
            // Commit may succeed before its caller observes cancellation or a timeout.
            await session.invalidateIdentityForUnitOfWork(token: token)
        }
        return result
    }

    /// Returns the transactional snapshot for a primary key, including local writes.
    public func find<E: Entity>(_ type: E.Type, _ primaryKey: E.PK) async throws -> E? {
        try beginOperation()
        defer { endOperation() }

        let primaryKeyValue = primaryKey.sqlValue
        let key = EntityKey(type: ObjectIdentifier(type), primaryKey: primaryKeyValue)
        let plan = try await session.unitOfWorkFindPlan(
            for: type,
            primaryKey: primaryKey,
            overlayState: overlay[key],
            useCachedEntity: !invalidatesSessionIdentity,
            token: token
        )
        if plan.isDeleted {
            return nil
        }
        if let cached = plan.cachedEntity {
            return cached
        }

        let rendered = try SQLRenderer(dialect: dialect).render(plan.statement)
        let result = try await executeTransaction(rendered.sql, rendered.parameters)
        guard result.rows.count <= 1 else {
            throw ORMError.multipleRowsForPrimaryKey(
                table: plan.tableName,
                primaryKey: primaryKeyValue
            )
        }
        guard let row = result.rows.first else { return nil }

        let entity = try E(row: row)
        let snapshot = try await session.unitOfWorkSnapshot(
            of: entity,
            token: token
        )
        guard snapshot.primaryKey == primaryKeyValue else {
            throw ORMError.hydratedPrimaryKeyMismatch(
                table: plan.tableName,
                expected: primaryKeyValue,
                actual: snapshot.primaryKey
            )
        }
        overlay[key] = .snapshot(snapshot)
        return entity
    }

    /// Executes a typed transactional SELECT and stages all returned snapshots atomically.
    public func fetch<E: Entity>(_ query: Query<E>) async throws -> [E] {
        try beginOperation()
        defer { endOperation() }

        let plan = try await session.unitOfWorkFetchPlan(for: query, token: token)
        let rendered = try SQLRenderer(dialect: dialect).render(plan.statement)
        let result = try await executeTransaction(rendered.sql, rendered.parameters)
        let batch = try await session.unitOfWorkHydrate(
            result.rows,
            as: E.self,
            token: token
        )
        for (key, snapshot) in batch.snapshots {
            overlay[key] = .snapshot(snapshot)
        }
        return batch.entities
    }

    /// Executes at most one transactional row and stages its identity snapshot.
    public func first<E: Entity>(_ query: Query<E>) async throws -> E? {
        try await fetch(query.firstQuery).first
    }

    /// Counts every transactional row matching the typed predicate before pagination.
    public func count<E: Entity>(_ query: Query<E>) async throws -> Int64 {
        try beginOperation()
        defer { endOperation() }

        let plan = try await session.unitOfWorkCountPlan(for: query, token: token)
        let rendered = try SQLRenderer(dialect: dialect).render(plan.statement)
        let result = try await executeTransaction(rendered.sql, rendered.parameters)
        return try decodeCount(result, table: plan.tableName)
    }

    /// Inserts one entity eagerly and returns the snapshot carrying its final primary key.
    public func insert<E: Entity>(_ entity: E) async throws -> E {
        try beginOperation()
        defer { endOperation() }

        var writeCompleted = false
        do {
            let usesReturning = dialect.capabilities.contains(.returning)
            let plan = try await session.unitOfWorkInsertPlan(
                for: entity,
                returning: usesReturning,
                token: token
            )
            let rendered = try SQLRenderer(dialect: dialect).render(plan.statement)

            if usesReturning {
                let result = try await executeTransaction(rendered.sql, rendered.parameters)
                writeCompleted = true
                try validateKnownAffectedRowCount(result.rowsAffected, table: plan.tableName)
                guard result.rows.count == 1, let row = result.rows.first else {
                    throw ORMError.unexpectedInsertResultRowCount(
                        table: plan.tableName,
                        actual: result.rows.count
                    )
                }
                let inserted = try E(row: row)
                return try await storeInserted(inserted, plan: plan)
            }

            if plan.primaryKeyIsGenerated {
                guard dialect.capabilities.contains(.lastInsertRowID) else {
                    throw ORMError.generatedPrimaryKeyRetrievalUnsupported(table: plan.tableName)
                }
                let result = try await executeTransaction(
                    rendered.sql,
                    rendered.parameters,
                    intent: .generatedRowIDInsert
                )
                writeCompleted = true
                guard result.rowsAffected == 1 else {
                    throw ORMError.unexpectedInsertAffectedRowCount(
                        table: plan.tableName,
                        actual: result.rowsAffected
                    )
                }
                guard let rowID = result.lastInsertRowID else {
                    throw ORMError.generatedPrimaryKeyUnavailable(table: plan.tableName)
                }
                let primaryKey = try E.PK(sqlValue: .int(rowID))
                return try await loadInserted(
                    E.self,
                    primaryKey: primaryKey,
                    table: plan.tableName
                )
            }

            let result = try await executeTransaction(
                rendered.sql,
                rendered.parameters
            )
            writeCompleted = true
            try validateKnownAffectedRowCount(result.rowsAffected, table: plan.tableName)
            return await stageInserted(entity, snapshot: plan.snapshot)
        } catch {
            if writeCompleted {
                rollbackOnly = true
            }
            throw error
        }
    }

    /// Updates the latest managed snapshot by its dirty mapped fields.
    /// `snapshot` must be the latest value returned by find, insert, or update.
    public func update<E: Entity>(_ entity: E, from snapshot: E) async throws -> E {
        try beginOperation()
        defer { endOperation() }

        var writeCompleted = false
        do {
            let usesReturning = dialect.capabilities.contains(.returning)
            let originalSnapshot = try await session.unitOfWorkSnapshot(
                of: snapshot,
                token: token
            )
            let primaryKey = originalSnapshot.primaryKey
            let key = EntityKey(type: ObjectIdentifier(E.self), primaryKey: primaryKey)
            let plan = try await session.unitOfWorkUpdatePlan(
                for: entity,
                from: originalSnapshot,
                overlayState: overlay[key],
                useCachedEntity: !invalidatesSessionIdentity,
                returning: usesReturning,
                token: token
            )

            guard let statement = plan.statement else {
                overlay[key] = .snapshot(plan.snapshot)
                return entity
            }

            let rendered = try SQLRenderer(dialect: dialect).render(statement)
            let result = try await executeTransaction(rendered.sql, rendered.parameters)
            writeCompleted = true
            await session.invalidateIdentityKeyForUnitOfWork(key, token: token)
            try validateUpdateAffectedRowCount(
                result.rowsAffected,
                table: plan.tableName,
                primaryKey: plan.primaryKey
            )

            if usesReturning {
                guard result.rows.count == 1, let row = result.rows.first else {
                    throw ORMError.unexpectedUpdateResultRowCount(
                        table: plan.tableName,
                        primaryKey: plan.primaryKey,
                        actual: result.rows.count
                    )
                }
                let updated = try E(row: row)
                let updatedSnapshot = try await session.unitOfWorkSnapshot(
                    of: updated,
                    token: token
                )
                guard updatedSnapshot.primaryKey == plan.primaryKey else {
                    throw ORMError.hydratedPrimaryKeyMismatch(
                        table: plan.tableName,
                        expected: plan.primaryKey,
                        actual: updatedSnapshot.primaryKey
                    )
                }
                overlay[key] = .snapshot(updatedSnapshot)
                return updated
            }

            overlay[key] = .snapshot(plan.snapshot)
            return entity
        } catch {
            if writeCompleted {
                rollbackOnly = true
            }
            throw error
        }
    }

    /// Deletes the latest managed snapshot and stages a tombstone for transactional reads.
    public func delete<E: Entity>(_ snapshot: E) async throws {
        try beginOperation()
        defer { endOperation() }

        var writeCompleted = false
        do {
            let originalSnapshot = try await session.unitOfWorkSnapshot(
                of: snapshot,
                token: token
            )
            let primaryKey = originalSnapshot.primaryKey
            let key = EntityKey(type: ObjectIdentifier(E.self), primaryKey: primaryKey)
            let plan = try await session.unitOfWorkDeletePlan(
                for: E.self,
                from: originalSnapshot,
                overlayState: overlay[key],
                useCachedEntity: !invalidatesSessionIdentity,
                token: token
            )
            let rendered = try SQLRenderer(dialect: dialect).render(plan.statement)
            let result = try await executeTransaction(rendered.sql, rendered.parameters)
            writeCompleted = true
            await session.invalidateIdentityKeyForUnitOfWork(key, token: token)
            try validateDeleteAffectedRowCount(
                result.rowsAffected,
                table: plan.tableName,
                primaryKey: plan.primaryKey
            )
            overlay[key] = .deleted
        } catch {
            if writeCompleted {
                rollbackOnly = true
            }
            throw error
        }
    }

    fileprivate func close() async throws -> UnitOfWorkChanges {
        switch lifecycle {
        case .open:
            lifecycle = .closing
            if inFlightOperations == 0 {
                finishClosing()
            }
        case .closing:
            break
        case .closed:
            guard !rollbackOnly else {
                throw SessionError.unitOfWorkRollbackOnly
            }
            return changes
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
        guard !rollbackOnly else {
            throw SessionError.unitOfWorkRollbackOnly
        }
        return changes
    }

    private func beginOperation() throws {
        guard lifecycle == .open else {
            throw SessionError.unitOfWorkClosed
        }
        guard !rollbackOnly else {
            throw SessionError.unitOfWorkRollbackOnly
        }
        guard inFlightOperations == 0 else {
            throw SessionError.unitOfWorkBusy
        }
        inFlightOperations += 1
    }

    private func endOperation() {
        precondition(inFlightOperations > 0)
        inFlightOperations -= 1
        if lifecycle == .closing, inFlightOperations == 0 {
            finishClosing()
        }
    }

    private func executeTransaction(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent = .arbitrary
    ) async throws -> ExecResult {
        do {
            return try await transaction.execute(sql, parameters, intent: intent)
        } catch {
            rollbackOnly = true
            throw error
        }
    }

    private func validateKnownAffectedRowCount(_ actual: Int?, table: String) throws {
        if let actual, actual != 1 {
            throw ORMError.unexpectedInsertAffectedRowCount(table: table, actual: actual)
        }
    }

    private func validateUpdateAffectedRowCount(
        _ actual: Int?,
        table: String,
        primaryKey: SQLValue
    ) throws {
        guard let actual else { return }
        if actual == 0 {
            throw ORMError.entityNotFound(table: table, primaryKey: primaryKey)
        }
        if actual != 1 {
            throw ORMError.unexpectedUpdateAffectedRowCount(
                table: table,
                primaryKey: primaryKey,
                actual: actual
            )
        }
    }

    private func validateDeleteAffectedRowCount(
        _ actual: Int?,
        table: String,
        primaryKey: SQLValue
    ) throws {
        guard let actual else { return }
        if actual == 0 {
            throw ORMError.entityNotFound(table: table, primaryKey: primaryKey)
        }
        if actual != 1 {
            throw ORMError.unexpectedDeleteAffectedRowCount(
                table: table,
                primaryKey: primaryKey,
                actual: actual
            )
        }
    }

    private var changes: UnitOfWorkChanges {
        UnitOfWorkChanges(
            invalidatesIdentity: invalidatesSessionIdentity,
            entities: overlay
        )
    }

    private func storeInserted<E: Entity>(
        _ inserted: E,
        plan: EntityInsertPlan
    ) async throws -> E {
        let snapshot = try await session.unitOfWorkSnapshot(of: inserted, token: token)
        if !plan.primaryKeyIsGenerated, snapshot.primaryKey != plan.primaryKey {
            throw ORMError.hydratedPrimaryKeyMismatch(
                table: plan.tableName,
                expected: plan.primaryKey,
                actual: snapshot.primaryKey
            )
        }
        return await stageInserted(inserted, snapshot: snapshot)
    }

    private func loadInserted<E: Entity>(
        _ type: E.Type,
        primaryKey: E.PK,
        table: String
    ) async throws -> E {
        let primaryKeyValue = primaryKey.sqlValue
        let plan = try await session.unitOfWorkFindPlan(
            for: type,
            primaryKey: primaryKey,
            overlayState: nil,
            useCachedEntity: false,
            token: token
        )
        let rendered = try SQLRenderer(dialect: dialect).render(plan.statement)
        let result = try await executeTransaction(rendered.sql, rendered.parameters)
        guard result.rows.count == 1, let row = result.rows.first else {
            throw ORMError.insertedRowLookupCount(
                table: table,
                primaryKey: primaryKeyValue,
                actual: result.rows.count
            )
        }
        let inserted = try E(row: row)
        let snapshot = try await session.unitOfWorkSnapshot(
            of: inserted,
            token: token
        )
        guard snapshot.primaryKey == primaryKeyValue else {
            throw ORMError.hydratedPrimaryKeyMismatch(
                table: table,
                expected: primaryKeyValue,
                actual: snapshot.primaryKey
            )
        }
        return await stageInserted(inserted, snapshot: snapshot)
    }

    private func stageInserted<E: Entity>(
        _ inserted: E,
        snapshot: ManagedEntitySnapshot
    ) async -> E {
        let key = EntityKey(type: ObjectIdentifier(E.self), primaryKey: snapshot.primaryKey)
        overlay[key] = .snapshot(snapshot)
        // COMMIT may succeed before its caller observes cancellation or a timeout.
        await session.invalidateIdentityKeyForUnitOfWork(key, token: token)
        return inserted
    }

    private func finishClosing() {
        lifecycle = .closed
        let waiters = closeWaiters
        closeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private func decodeCount(_ result: ExecResult, table: String) throws -> Int64 {
    guard result.rows.count == 1, let row = result.rows.first else {
        throw ORMError.unexpectedCountResultRowCount(
            table: table,
            actual: result.rows.count
        )
    }
    return try row.decode(SQLCount.resultColumn, as: Int64.self)
}

private func transactionControlCommand(in sql: String) -> String? {
    let keywords = leadingSQLKeywords(in: sql, limit: 2)
    guard let first = keywords.first else { return nil }

    switch first {
    case "BEGIN", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE":
        return first
    case "START", "PREPARE", "SET":
        guard keywords.count == 2, keywords[1] == "TRANSACTION" else { return nil }
        return "\(first) TRANSACTION"
    default:
        return nil
    }
}

private func leadingSQLKeywords(in sql: String, limit: Int) -> [String] {
    let bytes = Array(sql.utf8)
    var index = 0
    var keywords: [String] = []

    while keywords.count < limit {
        skipSQLTrivia(bytes, index: &index)
        let start = index
        while index < bytes.count, isSQLIdentifierByte(bytes[index]) {
            index += 1
        }
        guard start < index else { break }
        keywords.append(String(decoding: bytes[start ..< index], as: UTF8.self).uppercased())
    }
    return keywords
}

private func skipSQLTrivia(_ bytes: [UInt8], index: inout Int) {
    while index < bytes.count {
        if isSQLWhitespace(bytes[index]) || bytes[index] == UInt8(ascii: ";") {
            index += 1
            continue
        }
        if index + 1 < bytes.count,
           bytes[index] == UInt8(ascii: "-"),
           bytes[index + 1] == UInt8(ascii: "-") {
            index += 2
            while index < bytes.count,
                  bytes[index] != UInt8(ascii: "\n"),
                  bytes[index] != UInt8(ascii: "\r") {
                index += 1
            }
            continue
        }
        if index + 1 < bytes.count,
           bytes[index] == UInt8(ascii: "/"),
           bytes[index + 1] == UInt8(ascii: "*") {
            index += 2
            var depth = 1
            while index < bytes.count, depth > 0 {
                if index + 1 < bytes.count,
                   bytes[index] == UInt8(ascii: "/"),
                   bytes[index + 1] == UInt8(ascii: "*") {
                    depth += 1
                    index += 2
                } else if index + 1 < bytes.count,
                          bytes[index] == UInt8(ascii: "*"),
                          bytes[index + 1] == UInt8(ascii: "/") {
                    depth -= 1
                    index += 2
                } else {
                    index += 1
                }
            }
            continue
        }
        break
    }
}

private func isSQLWhitespace(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: " ") || (UInt8(ascii: "\t") ... UInt8(ascii: "\r")).contains(byte)
}

private func isSQLIdentifierByte(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
        || (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
        || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
        || byte == UInt8(ascii: "_")
        || byte == UInt8(ascii: "$")
}
