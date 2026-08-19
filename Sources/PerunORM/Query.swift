import PerunDBAL

/// Failures while resolving a typed ORM query into validated field metadata.
public enum ORMQueryError: Error, Sendable, Equatable {
    /// A query key path is absent from the entity's declared fields.
    case unmappedField(entity: String)
}

/// A typed façade over the backend-neutral DBAL predicate tree.
public struct Predicate<E: Entity>: Sendable, Hashable {
    let core: SQLPredicate

    init(core: SQLPredicate) {
        self.core = core
    }

    /// Matches rows whose mapped value equals `value`.
    public static func eq<Value: SQLValueConvertible>(
        _ keyPath: KeyPath<E, Value>,
        _ value: Value
    ) throws -> Self {
        try comparison(keyPath, op: .eq, value: value.sqlValue)
    }

    /// Matches rows whose mapped value does not equal `value`.
    public static func neq<Value: SQLValueConvertible>(
        _ keyPath: KeyPath<E, Value>,
        _ value: Value
    ) throws -> Self {
        try comparison(keyPath, op: .neq, value: value.sqlValue)
    }

    /// Matches rows whose mapped value is less than `value`.
    public static func lt<Value: SQLValueConvertible & Comparable>(
        _ keyPath: KeyPath<E, Value>,
        _ value: Value
    ) throws -> Self {
        try comparison(keyPath, op: .lt, value: value.sqlValue)
    }

    /// Matches rows whose mapped value is less than or equal to `value`.
    public static func lte<Value: SQLValueConvertible & Comparable>(
        _ keyPath: KeyPath<E, Value>,
        _ value: Value
    ) throws -> Self {
        try comparison(keyPath, op: .lte, value: value.sqlValue)
    }

    /// Matches rows whose mapped value is greater than `value`.
    public static func gt<Value: SQLValueConvertible & Comparable>(
        _ keyPath: KeyPath<E, Value>,
        _ value: Value
    ) throws -> Self {
        try comparison(keyPath, op: .gt, value: value.sqlValue)
    }

    /// Matches rows whose mapped value is greater than or equal to `value`.
    public static func gte<Value: SQLValueConvertible & Comparable>(
        _ keyPath: KeyPath<E, Value>,
        _ value: Value
    ) throws -> Self {
        try comparison(keyPath, op: .gte, value: value.sqlValue)
    }

    /// Matches a mapped string using the caller-provided SQL `LIKE` pattern.
    public static func like(
        _ keyPath: KeyPath<E, String>,
        _ pattern: String
    ) throws -> Self {
        try comparison(keyPath, op: .like, value: pattern.sqlValue)
    }

    /// Matches rows whose optional mapped value is SQL `NULL`.
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

    /// Matches rows whose mapped value belongs to `values`.
    ///
    /// An empty list is always false. A list containing an optional `nil` also matches SQL
    /// `NULL` while preserving the order of non-null bind values.
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

    /// Combines this predicate with `other` using logical AND.
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

    /// Combines this predicate with `other` using logical OR.
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

    /// Negates this predicate.
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

    /// Creates an unfiltered query selecting every mapped field from `entity`.
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

    var firstQuery: Self {
        let limit = statement.limit.map { Swift.min($0, 1) } ?? 1
        return Self(
            statement: SQLSelect(
                table: statement.table,
                columns: statement.columns,
                predicate: statement.predicate,
                orderings: statement.orderings,
                limit: limit,
                offset: statement.offset
            )
        )
    }

    var countStatement: SQLCount {
        SQLCount(table: statement.table, predicate: statement.predicate)
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
