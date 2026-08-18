import PerunDBAL

/// Failures while resolving a typed ORM query into validated field metadata.
public enum ORMQueryError: Error, Sendable, Equatable {
    case unmappedField(entity: String)
}

/// A typed façade over the backend-neutral DBAL predicate tree.
public struct Predicate<E: Entity>: Sendable, Hashable {
    let core: SQLPredicate

    init(core: SQLPredicate) {
        self.core = core
    }

    public static func eq<Value: SQLValueConvertible>(
        _ keyPath: KeyPath<E, Value>,
        _ value: Value
    ) throws -> Self {
        try comparison(keyPath, op: .eq, value: value.sqlValue)
    }

    public static func neq<Value: SQLValueConvertible>(
        _ keyPath: KeyPath<E, Value>,
        _ value: Value
    ) throws -> Self {
        try comparison(keyPath, op: .neq, value: value.sqlValue)
    }

    public static func lt<Value: SQLValueConvertible & Comparable>(
        _ keyPath: KeyPath<E, Value>,
        _ value: Value
    ) throws -> Self {
        try comparison(keyPath, op: .lt, value: value.sqlValue)
    }

    public static func lte<Value: SQLValueConvertible & Comparable>(
        _ keyPath: KeyPath<E, Value>,
        _ value: Value
    ) throws -> Self {
        try comparison(keyPath, op: .lte, value: value.sqlValue)
    }

    public static func gt<Value: SQLValueConvertible & Comparable>(
        _ keyPath: KeyPath<E, Value>,
        _ value: Value
    ) throws -> Self {
        try comparison(keyPath, op: .gt, value: value.sqlValue)
    }

    public static func gte<Value: SQLValueConvertible & Comparable>(
        _ keyPath: KeyPath<E, Value>,
        _ value: Value
    ) throws -> Self {
        try comparison(keyPath, op: .gte, value: value.sqlValue)
    }

    public static func like(
        _ keyPath: KeyPath<E, String>,
        _ pattern: String
    ) throws -> Self {
        try comparison(keyPath, op: .like, value: pattern.sqlValue)
    }

    public static func isNull<Value: SQLValueConvertible>(
        _ keyPath: KeyPath<E, Value?>
    ) throws -> Self {
        Self(
            core: .null(
                column: try queryColumn(for: E.self, keyPath: keyPath),
                negated: false
            )
        )
    }

    public static func `in`<Value: SQLValueConvertible>(
        _ keyPath: KeyPath<E, Value>,
        _ values: [Value]
    ) throws -> Self {
        Self(
            core: .inList(
                column: try queryColumn(for: E.self, keyPath: keyPath),
                values: values.map(\.sqlValue)
            )
        )
    }

    public func and(_ other: Self) -> Self {
        var predicates: [SQLPredicate]
        switch core {
        case let .and(existing):
            predicates = existing
        default:
            predicates = [core]
        }
        switch other.core {
        case let .and(existing):
            predicates.append(contentsOf: existing)
        default:
            predicates.append(other.core)
        }
        return Self(core: .and(predicates))
    }

    public func or(_ other: Self) -> Self {
        var predicates: [SQLPredicate]
        switch core {
        case let .or(existing):
            predicates = existing
        default:
            predicates = [core]
        }
        switch other.core {
        case let .or(existing):
            predicates.append(contentsOf: existing)
        default:
            predicates.append(other.core)
        }
        return Self(core: .or(predicates))
    }

    public func not() -> Self {
        Self(core: .not(core))
    }

    private static func comparison<Value>(
        _ keyPath: KeyPath<E, Value>,
        op: ComparisonOp,
        value: SQLValue
    ) throws -> Self {
        Self(
            core: .comparison(
                column: try queryColumn(for: E.self, keyPath: keyPath),
                op: op,
                value: value
            )
        )
    }
}

/// A typed, immutable single-entity SELECT description.
public struct Query<E: Entity>: Sendable, Hashable {
    let statement: SQLSelect

    public init(_ entity: E.Type = E.self) throws {
        let schema = try EntitySchema(entity)
        statement = SQLSelect(
            table: schema.tableName,
            columns: schema.fields.map(\.column)
        )
    }

    private init(statement: SQLSelect) {
        self.statement = statement
    }

    /// Adds a predicate. Repeated calls are combined with AND in call order.
    public func `where`(_ predicate: Predicate<E>) -> Self {
        let combined: SQLPredicate
        if let existing = statement.predicate {
            combined = Predicate<E>(core: existing).and(predicate).core
        } else {
            combined = predicate.core
        }
        return Self(
            statement: SQLSelect(
                table: statement.table,
                columns: statement.columns,
                predicate: combined,
                orderings: statement.orderings,
                limit: statement.limit,
                offset: statement.offset
            )
        )
    }

    /// Appends one mapped field ordering in call order.
    public func order<Value>(
        by keyPath: KeyPath<E, Value>,
        desc: Bool = false
    ) throws -> Self {
        var orderings = statement.orderings
        orderings.append(
            SQLOrdering(
                column: try queryColumn(for: E.self, keyPath: keyPath),
                direction: desc ? .descending : .ascending
            )
        )
        return Self(
            statement: SQLSelect(
                table: statement.table,
                columns: statement.columns,
                predicate: statement.predicate,
                orderings: orderings,
                limit: statement.limit,
                offset: statement.offset
            )
        )
    }

    /// Replaces pagination. A zero offset is normalized to no OFFSET clause.
    public func limit(_ count: Int, offset: Int = 0) -> Self {
        Self(
            statement: SQLSelect(
                table: statement.table,
                columns: statement.columns,
                predicate: statement.predicate,
                orderings: statement.orderings,
                limit: count,
                offset: offset == 0 ? nil : offset
            )
        )
    }
}

private func queryColumn<E: Entity, Value>(
    for entity: E.Type,
    keyPath: KeyPath<E, Value>
) throws -> String {
    let schema = try EntitySchema(entity)
    guard let field = schema.fields.first(where: { $0.keyPath == keyPath }) else {
        throw ORMQueryError.unmappedField(entity: String(reflecting: entity))
    }
    return field.column
}
