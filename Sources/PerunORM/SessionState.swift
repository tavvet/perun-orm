import PerunDBAL

struct EntityKey: Sendable, Hashable {
    let type: ObjectIdentifier
    let primaryKey: SQLValue
}

struct EntityFindPlan<E: Entity>: Sendable {
    let tableName: String
    let statement: SQLSelect
    let cachedEntity: E?
    let isDeleted: Bool
}

struct EntityFetchPlan: Sendable {
    let statement: SQLSelect
}

struct EntityCountPlan: Sendable {
    let tableName: String
    let statement: SQLCount
}

struct ManagedEntitySnapshot: Sendable {
    let entityType: ObjectIdentifier
    let mappedValues: [SQLValue]
    let primaryKey: SQLValue
}

enum ManagedEntityState: Sendable {
    case snapshot(ManagedEntitySnapshot)
    case deleted
}

struct EntityFetchBatch<E: Entity>: Sendable {
    let entities: [E]
    let snapshots: [EntityKey: ManagedEntitySnapshot]
}

struct EntityInsertPlan: Sendable {
    let tableName: String
    let statement: SQLInsert
    let primaryKey: SQLValue
    let primaryKeyIsGenerated: Bool
    let snapshot: ManagedEntitySnapshot
}

struct EntityUpdatePlan: Sendable {
    let tableName: String
    let statement: SQLUpdate?
    let primaryKey: SQLValue
    let snapshot: ManagedEntitySnapshot
}

struct EntityDeletePlan: Sendable {
    let tableName: String
    let statement: SQLDelete
    let primaryKey: SQLValue
}

struct UnitOfWorkChanges: Sendable {
    let invalidatesIdentity: Bool
    let entities: [EntityKey: ManagedEntityState]
}

struct UnitOfWorkOutcome<Value: Sendable>: Sendable {
    let value: Value
    let changes: UnitOfWorkChanges
}

struct SessionIdentityMap {
    private var snapshots: [EntityKey: ManagedEntitySnapshot] = [:]

    private(set) var revision: UInt64 = 0

    subscript(key: EntityKey) -> ManagedEntitySnapshot? {
        get { snapshots[key] }
        set { snapshots[key] = newValue }
    }

    mutating func invalidate() {
        revision &+= 1
        snapshots.removeAll(keepingCapacity: true)
    }

    mutating func removeValue(forKey key: EntityKey) {
        snapshots.removeValue(forKey: key)
    }

    mutating func apply(_ changes: UnitOfWorkChanges) {
        if changes.invalidatesIdentity {
            invalidate()
        }
        for (key, state) in changes.entities {
            switch state {
            case let .snapshot(snapshot):
                snapshots[key] = snapshot
            case .deleted:
                snapshots.removeValue(forKey: key)
            }
        }
    }
}

struct EntitySchemaCache {
    private var schemas: [ObjectIdentifier: Any] = [:]

    mutating func schema<E: Entity>(for type: E.Type) throws -> EntitySchema<E> {
        let key = ObjectIdentifier(type)
        if let cached = schemas[key] {
            guard let schema = cached as? EntitySchema<E> else {
                preconditionFailure("entity type key resolved to a different validated schema")
            }
            return schema
        }

        let schema = try EntitySchema(type)
        schemas[key] = schema
        return schema
    }
}

func decodeCount(_ result: ExecResult, table: String) throws -> Int64 {
    guard result.rows.count == 1, let row = result.rows.first else {
        throw ORMError.unexpectedCountResultRowCount(
            table: table,
            actual: result.rows.count
        )
    }
    return try row.decode(SQLCount.resultColumn, as: Int64.self)
}
