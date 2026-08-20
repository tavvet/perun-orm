import Foundation
import PerunDBAL

extension Session {
    func validatedSchema<E: Entity>(for type: E.Type) throws -> EntitySchema<E> {
        try schemaCache.schema(for: type)
    }

    func unitOfWorkFindPlan<E: Entity>(
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
            cachedSnapshot = useCachedEntity ? identityMap[key] : nil
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

    func unitOfWorkFetchPlan<E: Entity>(
        for query: Query<E>,
        token: UUID
    ) throws -> EntityFetchPlan {
        try validateUnitOfWork(token)
        _ = try validatedSchema(for: E.self)
        return EntityFetchPlan(statement: query.statement)
    }

    func unitOfWorkHydrate<E: Entity>(
        _ rows: [any Row],
        as type: E.Type,
        token: UUID
    ) throws -> EntityFetchBatch<E> {
        try validateUnitOfWork(token)
        let schema = try validatedSchema(for: type)
        return try hydrate(rows, schema: schema)
    }

    func unitOfWorkValidateRawFetch<E: Entity>(
        for type: E.Type,
        token: UUID
    ) throws {
        try validateUnitOfWork(token)
        _ = try validatedSchema(for: type)
    }

    func unitOfWorkCountPlan<E: Entity>(
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

    func unitOfWorkInsertPlan<E: Entity>(
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

    func unitOfWorkUpdatePlan<E: Entity>(
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
            cachedSnapshot = useCachedEntity ? identityMap[key] : nil
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

    func unitOfWorkDeletePlan<E: Entity>(
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
            cachedSnapshot = useCachedEntity ? identityMap[key] : nil
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

    func unitOfWorkSnapshot<E: Entity>(
        of entity: E,
        token: UUID
    ) throws -> ManagedEntitySnapshot {
        try validateUnitOfWork(token)
        let schema = try validatedSchema(for: E.self)
        return managedSnapshot(of: entity, schema: schema)
    }

    func invalidateIdentityForUnitOfWork(token: UUID) {
        precondition(activeUnitOfWork == token)
        invalidateIdentity()
    }

    func invalidateIdentityKeyForUnitOfWork(_ key: EntityKey, token: UUID) {
        precondition(activeUnitOfWork == token)
        identityMap.removeValue(forKey: key)
    }

    private func validateUnitOfWork(_ token: UUID) throws {
        guard activeUnitOfWork == token else {
            throw SessionError.unitOfWorkClosed
        }
    }

    func managedSnapshot<E: Entity>(
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

    func hydrate<E: Entity>(
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
