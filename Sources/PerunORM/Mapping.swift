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
    let containsReferenceType: Bool

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
        containsReferenceType = typeContainsReference(Value.self)
    }

    public func read(from root: Root) -> SQLValue {
        readValue(root)
    }
}

/// A persistable value-semantic type. Reference entities and reference-typed mapped
/// fields are rejected by `EntitySchema` because snapshots require value semantics.
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
    case referenceTypeUnsupported
    case referenceFieldTypeUnsupported(column: String)
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

enum EntitySnapshotRowError: Error, Sendable, Equatable {
    case missingColumn(String)
    case columnTypeMismatch(column: String, expected: ColumnType, actual: ColumnType)
}

private struct EntitySnapshotCell: Sendable {
    let type: ColumnType
    let value: SQLValue
}

private struct EntitySnapshotRow: Row {
    let cells: [String: EntitySnapshotCell]

    func decode<T: SQLValueConvertible>(_ column: String, as type: T.Type) throws -> T {
        let cell = try cell(for: column, requestedType: T.columnType)
        return try T(sqlValue: cell.value)
    }

    func decodeIfPresent<T: SQLValueConvertible>(
        _ column: String,
        as type: T.Type
    ) throws -> T? {
        let cell = try cell(for: column, requestedType: T.columnType)
        guard cell.value != .null else { return nil }
        return try T(sqlValue: cell.value)
    }

    private func cell(
        for column: String,
        requestedType: ColumnType
    ) throws -> EntitySnapshotCell {
        guard let cell = cells[column] else {
            throw EntitySnapshotRowError.missingColumn(column)
        }
        guard cell.type == requestedType else {
            throw EntitySnapshotRowError.columnTypeMismatch(
                column: column,
                expected: cell.type,
                actual: requestedType
            )
        }
        return cell
    }
}

/// Validated, single-source metadata derived from `Entity.fields`.
public struct EntitySchema<E: Entity> {
    public let tableName: String
    public let fields: [FieldDescriptor<E>]
    public let primaryKey: FieldDescriptor<E>

    public init(_ entity: E.Type = E.self) throws {
        guard !(entity is AnyObject.Type) else {
            throw EntitySchemaError.referenceTypeUnsupported
        }
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
            guard !field.containsReferenceType else {
                throw EntitySchemaError.referenceFieldTypeUnsupported(column: field.column)
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

extension EntitySchema {
    func mappedValues(of entity: E) -> [SQLValue] {
        fields.map { $0.read(from: entity) }
    }

    func primaryKeyValue(in mappedValues: [SQLValue]) -> SQLValue {
        precondition(mappedValues.count == fields.count)
        guard let index = fields.firstIndex(where: { field in
            if case .primaryKey = field.role { return true }
            return false
        }) else {
            preconditionFailure("validated entity schema lost its primary key")
        }
        return mappedValues[index]
    }

    func materialize(from mappedValues: [SQLValue]) throws -> E {
        precondition(mappedValues.count == fields.count)
        var cells: [String: EntitySnapshotCell] = [:]
        cells.reserveCapacity(fields.count)
        for (index, field) in fields.enumerated() {
            cells[field.column] = EntitySnapshotCell(
                type: field.type,
                value: mappedValues[index]
            )
        }
        return try E(row: EntitySnapshotRow(cells: cells))
    }

    var primaryKeyIsGenerated: Bool {
        if case .primaryKey(generated: true) = primaryKey.role {
            return true
        }
        return false
    }

    var createTableStatement: SQLCreateTable {
        SQLCreateTable(
            table: tableName,
            columns: fields.map { field in
                SQLColumnDefinition(
                    name: field.column,
                    type: field.type,
                    nullable: field.isNullable,
                    unique: field.isUnique,
                    role: field.role.sqlRole
                )
            }
        )
    }

    func insertStatement(_ entity: E, returning: Bool) -> SQLInsert {
        insertStatement(mappedValues: mappedValues(of: entity), returning: returning)
    }

    func insertStatement(mappedValues: [SQLValue], returning: Bool) -> SQLInsert {
        precondition(mappedValues.count == fields.count)
        return SQLInsert(
            table: tableName,
            values: fields.enumerated().compactMap { index, field in
                if case .primaryKey(generated: true) = field.role {
                    return nil
                }
                return SQLColumnValue(
                    column: field.column,
                    value: mappedValues[index]
                )
            },
            returning: returning ? fields.map(\.column) : []
        )
    }

    func updateStatement(
        _ entity: E,
        comparedTo snapshot: E,
        returning: Bool
    ) -> SQLUpdate? {
        updateStatement(
            mappedValues: mappedValues(of: entity),
            comparedTo: mappedValues(of: snapshot),
            returning: returning
        )
    }

    func updateStatement(
        mappedValues: [SQLValue],
        comparedTo snapshotValues: [SQLValue],
        returning: Bool
    ) -> SQLUpdate? {
        precondition(mappedValues.count == fields.count)
        precondition(snapshotValues.count == fields.count)
        let assignments = fields.enumerated().compactMap { index, field -> SQLColumnValue? in
            if case .primaryKey = field.role {
                return nil
            }
            let value = mappedValues[index]
            guard !value.isSameSnapshotValue(as: snapshotValues[index]) else { return nil }
            return SQLColumnValue(column: field.column, value: value)
        }
        guard !assignments.isEmpty else { return nil }

        return SQLUpdate(
            table: tableName,
            assignments: assignments,
            predicate: .comparison(
                column: primaryKey.column,
                op: .eq,
                value: primaryKeyValue(in: mappedValues)
            ),
            returning: returning ? fields.map(\.column) : []
        )
    }

    func deleteStatement(primaryKey: SQLValue) -> SQLDelete {
        SQLDelete(
            table: tableName,
            predicate: .comparison(
                column: self.primaryKey.column,
                op: .eq,
                value: primaryKey
            )
        )
    }

    func hasSameMappedValues(_ lhs: E, _ rhs: E) -> Bool {
        hasSameMappedValues(mappedValues(of: lhs), mappedValues(of: rhs))
    }

    func hasSameMappedValues(_ entity: E, _ snapshotValues: [SQLValue]) -> Bool {
        hasSameMappedValues(mappedValues(of: entity), snapshotValues)
    }

    func hasSameMappedValues(_ lhs: [SQLValue], _ rhs: [SQLValue]) -> Bool {
        guard lhs.count == fields.count, rhs.count == fields.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.isSameSnapshotValue(as: right)
        }
    }

    func findStatement(primaryKey: E.PK) -> SQLSelect {
        SQLSelect(
            table: tableName,
            columns: fields.map(\.column),
            predicate: .comparison(
                column: self.primaryKey.column,
                op: .eq,
                value: primaryKey.sqlValue
            ),
            limit: 2
        )
    }
}

private protocol OptionalTypeMetadata {
    static var wrappedType: Any.Type { get }
}

extension Optional: OptionalTypeMetadata {
    fileprivate static var wrappedType: Any.Type { Wrapped.self }
}

private func typeContainsReference(_ type: Any.Type) -> Bool {
    if type is AnyObject.Type {
        return true
    }
    guard let optional = type as? any OptionalTypeMetadata.Type else {
        return false
    }
    return typeContainsReference(optional.wrappedType)
}

private extension SQLValue {
    func isSameSnapshotValue(as other: SQLValue) -> Bool {
        if case let (.double(lhs), .double(rhs)) = (self, other),
           lhs.isNaN, rhs.isNaN {
            return true
        }
        return self == other
    }
}

private extension ColumnRole {
    var sqlRole: SQLColumnRole {
        switch self {
        case .attribute:
            .attribute
        case let .primaryKey(generated):
            .primaryKey(generated: generated)
        }
    }
}
