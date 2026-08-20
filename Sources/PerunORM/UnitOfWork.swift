import Foundation
import PerunDBAL

/// The scoped transactional executor. Its snapshots reach the session only after commit.
/// Closing it releases its transaction and session execution context.
public actor UnitOfWork {
    private enum Lifecycle: Equatable {
        case open
        case closing
        case closed
    }

    private struct ExecutionContext: Sendable {
        let transaction: any Transaction
        let session: Session
        let token: UUID
    }

    private let dialect: any SQLDialect
    private var executionContext: ExecutionContext?
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
        self.dialect = dialect
        executionContext = ExecutionContext(
            transaction: transaction,
            session: session,
            token: token
        )
    }

    /// Executes one raw statement. Success invalidates prior ORM snapshots conservatively;
    /// transaction-control statements are rejected and make this unit of work rollback-only.
    public func execute(_ sql: String, _ parameters: [SQLValue] = []) async throws -> ExecResult {
        try beginOperation()
        defer { endOperation() }

        if let command = sqlTransactionControlCommand(in: sql) {
            rollbackOnly = true
            throw SessionError.transactionControlNotAllowed(command: command)
        }

        let result = try await executeTransaction(sql, parameters)
        await invalidateSnapshotsAfterRawExecution()
        return result
    }

    /// Returns the transactional snapshot for a primary key, including local writes.
    public func find<E: Entity>(_ type: E.Type, _ primaryKey: E.PK) async throws -> E? {
        try beginOperation()
        defer { endOperation() }

        let primaryKeyValue = primaryKey.sqlValue
        let key = EntityKey(type: ObjectIdentifier(type), primaryKey: primaryKeyValue)
        let plan = try await currentContext.session.unitOfWorkFindPlan(
            for: type,
            primaryKey: primaryKey,
            overlayState: overlay[key],
            useCachedEntity: !invalidatesSessionIdentity,
            token: currentContext.token
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
        let snapshot = try await currentContext.session.unitOfWorkSnapshot(
            of: entity,
            token: currentContext.token
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

        let plan = try await currentContext.session.unitOfWorkFetchPlan(
            for: query,
            token: currentContext.token
        )
        let rendered = try SQLRenderer(dialect: dialect).render(plan.statement)
        let result = try await executeTransaction(rendered.sql, rendered.parameters)
        let batch = try await currentContext.session.unitOfWorkHydrate(
            result.rows,
            as: E.self,
            token: currentContext.token
        )
        for (key, snapshot) in batch.snapshots {
            overlay[key] = .snapshot(snapshot)
        }
        return batch.entities
    }

    /// Executes caller-owned SQL and atomically hydrates detached entities in this transaction.
    /// Because the statement may write, post-execution hydration errors force rollback.
    public func fetch<E: Entity>(
        _ type: E.Type,
        sql: String,
        params: [SQLValue] = []
    ) async throws -> [E] {
        try beginOperation()
        defer { endOperation() }

        if let command = sqlTransactionControlCommand(in: sql) {
            rollbackOnly = true
            throw SessionError.transactionControlNotAllowed(command: command)
        }

        try await currentContext.session.unitOfWorkValidateRawFetch(
            for: type,
            token: currentContext.token
        )
        var executionCompleted = false
        do {
            let result = try await executeTransaction(sql, params)
            executionCompleted = true
            await invalidateSnapshotsAfterRawExecution()
            let batch = try await currentContext.session.unitOfWorkHydrate(
                result.rows,
                as: type,
                token: currentContext.token
            )
            return batch.entities
        } catch {
            if executionCompleted {
                rollbackOnly = true
            }
            throw error
        }
    }

    /// Executes at most one transactional row and stages its identity snapshot.
    public func first<E: Entity>(_ query: Query<E>) async throws -> E? {
        try await fetch(query.firstQuery).first
    }

    /// Counts every transactional row matching the typed predicate before pagination.
    public func count<E: Entity>(_ query: Query<E>) async throws -> Int64 {
        try beginOperation()
        defer { endOperation() }

        let plan = try await currentContext.session.unitOfWorkCountPlan(
            for: query,
            token: currentContext.token
        )
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
            let plan = try await currentContext.session.unitOfWorkInsertPlan(
                for: entity,
                returning: usesReturning,
                token: currentContext.token
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
            let originalSnapshot = try await currentContext.session.unitOfWorkSnapshot(
                of: snapshot,
                token: currentContext.token
            )
            let primaryKey = originalSnapshot.primaryKey
            let key = EntityKey(type: ObjectIdentifier(E.self), primaryKey: primaryKey)
            let plan = try await currentContext.session.unitOfWorkUpdatePlan(
                for: entity,
                from: originalSnapshot,
                overlayState: overlay[key],
                useCachedEntity: !invalidatesSessionIdentity,
                returning: usesReturning,
                token: currentContext.token
            )

            guard let statement = plan.statement else {
                overlay[key] = .snapshot(plan.snapshot)
                return entity
            }

            let rendered = try SQLRenderer(dialect: dialect).render(statement)
            let result = try await executeTransaction(rendered.sql, rendered.parameters)
            writeCompleted = true
            await currentContext.session.invalidateIdentityKeyForUnitOfWork(
                key,
                token: currentContext.token
            )
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
                let updatedSnapshot = try await currentContext.session.unitOfWorkSnapshot(
                    of: updated,
                    token: currentContext.token
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
            let originalSnapshot = try await currentContext.session.unitOfWorkSnapshot(
                of: snapshot,
                token: currentContext.token
            )
            let primaryKey = originalSnapshot.primaryKey
            let key = EntityKey(type: ObjectIdentifier(E.self), primaryKey: primaryKey)
            let plan = try await currentContext.session.unitOfWorkDeletePlan(
                for: E.self,
                from: originalSnapshot,
                overlayState: overlay[key],
                useCachedEntity: !invalidatesSessionIdentity,
                token: currentContext.token
            )
            let rendered = try SQLRenderer(dialect: dialect).render(plan.statement)
            let result = try await executeTransaction(rendered.sql, rendered.parameters)
            writeCompleted = true
            await currentContext.session.invalidateIdentityKeyForUnitOfWork(
                key,
                token: currentContext.token
            )
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

    func close() async throws -> UnitOfWorkChanges {
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
        guard executionContext != nil else {
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
            return try await currentContext.transaction.execute(
                sql,
                parameters,
                intent: intent
            )
        } catch {
            rollbackOnly = true
            throw error
        }
    }

    private func invalidateSnapshotsAfterRawExecution() async {
        let shouldInvalidateBaseIdentity = !invalidatesSessionIdentity
        invalidatesSessionIdentity = true
        overlay.removeAll(keepingCapacity: true)
        if shouldInvalidateBaseIdentity {
            // COMMIT may succeed before its caller observes cancellation or a timeout.
            await currentContext.session.invalidateIdentityForUnitOfWork(
                token: currentContext.token
            )
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
        let snapshot = try await currentContext.session.unitOfWorkSnapshot(
            of: inserted,
            token: currentContext.token
        )
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
        let plan = try await currentContext.session.unitOfWorkFindPlan(
            for: type,
            primaryKey: primaryKey,
            overlayState: nil,
            useCachedEntity: false,
            token: currentContext.token
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
        let snapshot = try await currentContext.session.unitOfWorkSnapshot(
            of: inserted,
            token: currentContext.token
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
        await currentContext.session.invalidateIdentityKeyForUnitOfWork(
            key,
            token: currentContext.token
        )
        return inserted
    }

    private var currentContext: ExecutionContext {
        guard let executionContext else {
            preconditionFailure("closed unit of work lost its execution context")
        }
        return executionContext
    }

    private func finishClosing() {
        lifecycle = .closed
        executionContext = nil
        let waiters = closeWaiters
        closeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
