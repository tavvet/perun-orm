import PerunDBAL

public enum ColumnRole: Sendable, Hashable {
    case attribute
    case primaryKey(generated: Bool)
}

/// Type-erased field metadata for one concrete entity type.
public struct FieldDescriptor<Root: Sendable> {
    public let column: String
    public let type: ColumnType
    public let isNullable: Bool
    public let isUnique: Bool
    public let role: ColumnRole
    public let keyPath: PartialKeyPath<Root>

    let readValue: (Root) -> SQLValue

    public init<Value: SQLValueConvertible>(
        _ keyPath: KeyPath<Root, Value>,
        column: String,
        unique: Bool = false,
        role: ColumnRole = .attribute
    ) {
        self.column = column
        type = Value.columnType
        isNullable = Value.isNullable
        isUnique = unique
        self.role = role
        self.keyPath = keyPath
        readValue = { root in root[keyPath: keyPath].sqlValue }
    }

    public func read(from root: Root) -> SQLValue {
        readValue(root)
    }
}

public protocol Entity: Sendable {
    associatedtype PK: SQLValueConvertible & Hashable

    static var tableName: String { get }
    static var fields: [FieldDescriptor<Self>] { get }

    init(row: any Row) throws
}

public extension Entity {
    static func field(for keyPath: PartialKeyPath<Self>) -> FieldDescriptor<Self>? {
        fields.first { $0.keyPath == keyPath }
    }
}

public enum EntitySchemaError: Error, Sendable, Equatable {
    case emptyTableName
    case noFields
    case emptyColumn(index: Int)
    case duplicateColumn(String)
    case duplicateKeyPath(column: String)
    case primaryKeyCount(Int)
    case nullablePrimaryKey(String)
    case primaryKeyTypeMismatch(expected: ColumnType, actual: ColumnType)
    case unsupportedPrimaryKeyType(ColumnType)
    case generatedPrimaryKeyRequiresInt64(column: String, actual: ColumnType)
}

/// Validated, single-source metadata derived from `Entity.fields`.
public struct EntitySchema<E: Entity> {
    public let tableName: String
    public let fields: [FieldDescriptor<E>]
    public let primaryKey: FieldDescriptor<E>

    public init(_ entity: E.Type = E.self) throws {
        guard !E.tableName.isEmpty else {
            throw EntitySchemaError.emptyTableName
        }
        let declaredFields = E.fields
        guard !declaredFields.isEmpty else {
            throw EntitySchemaError.noFields
        }

        var columns: Set<String> = []
        var keyPaths: Set<AnyKeyPath> = []
        for (index, field) in declaredFields.enumerated() {
            guard !field.column.isEmpty else {
                throw EntitySchemaError.emptyColumn(index: index)
            }
            guard columns.insert(field.column.lowercased()).inserted else {
                throw EntitySchemaError.duplicateColumn(field.column)
            }
            guard keyPaths.insert(field.keyPath).inserted else {
                throw EntitySchemaError.duplicateKeyPath(column: field.column)
            }
        }

        let primaryKeys = declaredFields.filter {
            if case .primaryKey = $0.role { return true }
            return false
        }
        guard primaryKeys.count == 1, let primaryKey = primaryKeys.first else {
            throw EntitySchemaError.primaryKeyCount(primaryKeys.count)
        }
        guard !primaryKey.isNullable else {
            throw EntitySchemaError.nullablePrimaryKey(primaryKey.column)
        }
        guard !E.PK.isNullable else {
            throw EntitySchemaError.nullablePrimaryKey(primaryKey.column)
        }
        guard primaryKey.type == E.PK.columnType else {
            throw EntitySchemaError.primaryKeyTypeMismatch(
                expected: E.PK.columnType,
                actual: primaryKey.type
            )
        }
        switch primaryKey.type {
        case .boolean, .int32, .int64, .text, .blob, .uuid:
            break
        case .double, .timestamp:
            throw EntitySchemaError.unsupportedPrimaryKeyType(primaryKey.type)
        }
        if case .primaryKey(generated: true) = primaryKey.role,
           primaryKey.type != .int64 {
            throw EntitySchemaError.generatedPrimaryKeyRequiresInt64(
                column: primaryKey.column,
                actual: primaryKey.type
            )
        }

        tableName = E.tableName
        fields = declaredFields
        self.primaryKey = primaryKey
    }
}
