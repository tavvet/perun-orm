/// One rendered statement and its positional bind values.
public struct RenderedSQL: Sendable, Hashable {
    public let sql: String
    public let parameters: [SQLValue]

    public init(sql: String, parameters: [SQLValue]) {
        self.sql = sql
        self.parameters = parameters
    }
}

public enum ComparisonOp: Sendable, Hashable {
    case eq
    case neq
    case lt
    case lte
    case gt
    case gte
    case like
}

/// A backend-neutral predicate over one table. Column names are identifiers, never SQL fragments.
public indirect enum SQLPredicate: Sendable, Hashable {
    case comparison(column: String, op: ComparisonOp, value: SQLValue)
    case inList(column: String, values: [SQLValue])
    case null(column: String, negated: Bool)
    case and([SQLPredicate])
    case or([SQLPredicate])
    case not(SQLPredicate)
}

public enum SQLSortDirection: Sendable, Hashable {
    case ascending
    case descending
}

public struct SQLOrdering: Sendable, Hashable {
    public let column: String
    public let direction: SQLSortDirection

    public init(column: String, direction: SQLSortDirection = .ascending) {
        self.column = column
        self.direction = direction
    }
}

/// A single-table SELECT. Projections and orderings are identifier-only in the v0.1 slice.
public struct SQLSelect: Sendable, Hashable {
    public let table: String
    public let columns: [String]
    public let predicate: SQLPredicate?
    public let orderings: [SQLOrdering]
    public let limit: Int?
    public let offset: Int?

    public init(
        table: String,
        columns: [String],
        predicate: SQLPredicate? = nil,
        orderings: [SQLOrdering] = [],
        limit: Int? = nil,
        offset: Int? = nil
    ) {
        self.table = table
        self.columns = columns
        self.predicate = predicate
        self.orderings = orderings
        self.limit = limit
        self.offset = offset
    }
}

public enum SQLRenderError: Error, Sendable, Equatable {
    case emptyTable
    case noSelectedColumns
    case emptyColumn
    case identifierContainsNullByte
    case nullComparison(ComparisonOp)
    case negativeLimit(Int)
    case negativeOffset(Int)
    case offsetRequiresLimit
}

/// Pure renderer: it never executes SQL and owns no mutable state between calls.
public struct SQLRenderer: Sendable {
    public let dialect: any SQLDialect

    public init(dialect: any SQLDialect) {
        self.dialect = dialect
    }

    public func render(_ select: SQLSelect) throws -> RenderedSQL {
        try validateTable(select.table)
        guard !select.columns.isEmpty else {
            throw SQLRenderError.noSelectedColumns
        }
        try select.columns.forEach(validateColumn)
        try select.orderings.forEach { try validateColumn($0.column) }
        try validatePagination(limit: select.limit, offset: select.offset)

        let pagination = try select.limit.map { limit in
            try dialect.paginationPlan(
                limit: limit,
                offset: select.offset,
                context: SQLPaginationContext(hasOrderings: !select.orderings.isEmpty)
            )
        }

        var binder = ParamBinder(dialect: dialect)
        let projection = select.columns
            .map(dialect.quoteIdentifier)
            .joined(separator: ", ")
        var sql = "SELECT"
        if let pagination, pagination.placement == .afterSelect {
            sql += " " + render(pagination, binder: &binder)
        }
        sql += " \(projection) FROM \(dialect.quoteIdentifier(select.table))"

        if let predicate = select.predicate {
            sql += " WHERE \(try render(predicate, binder: &binder))"
        }

        if !select.orderings.isEmpty {
            let orderings = select.orderings.map { ordering in
                let direction = ordering.direction == .ascending ? "ASC" : "DESC"
                return "\(dialect.quoteIdentifier(ordering.column)) \(direction)"
            }
            sql += " ORDER BY \(orderings.joined(separator: ", "))"
        }

        if let pagination, pagination.placement == .suffix {
            sql += " " + render(pagination, binder: &binder)
        }

        return RenderedSQL(sql: sql, parameters: binder.parameters)
    }

    private func render(
        _ pagination: SQLPaginationPlan,
        binder: inout ParamBinder
    ) -> String {
        pagination.fragments.map { fragment in
            switch fragment {
            case let .literal(sql):
                sql
            case let .parameter(value):
                binder.bind(.int(Int64(value)))
            }
        }.joined()
    }

    private func render(
        _ predicate: SQLPredicate,
        binder: inout ParamBinder
    ) throws -> String {
        switch predicate {
        case let .comparison(column, op, value):
            try validateColumn(column)
            let column = dialect.quoteIdentifier(column)
            if case .null = value {
                switch op {
                case .eq:
                    return "\(column) IS NULL"
                case .neq:
                    return "\(column) IS NOT NULL"
                case .lt, .lte, .gt, .gte, .like:
                    throw SQLRenderError.nullComparison(op)
                }
            }
            return "\(column) \(op.sql) \(binder.bind(value))"

        case let .inList(column, values):
            try validateColumn(column)
            let column = dialect.quoteIdentifier(column)
            let nonNullValues = values.filter { value in
                if case .null = value { return false }
                return true
            }
            let containsNull = nonNullValues.count != values.count

            guard !nonNullValues.isEmpty else {
                return containsNull ? "\(column) IS NULL" : "1 = 0"
            }

            let placeholders = nonNullValues
                .map { binder.bind($0) }
                .joined(separator: ", ")
            let membership = "\(column) IN (\(placeholders))"
            return containsNull ? "(\(membership) OR \(column) IS NULL)" : membership

        case let .null(column, negated):
            try validateColumn(column)
            return "\(dialect.quoteIdentifier(column)) IS \(negated ? "NOT " : "")NULL"

        case let .and(predicates):
            return try renderGroup(predicates, separator: " AND ", empty: "1 = 1", binder: &binder)

        case let .or(predicates):
            return try renderGroup(predicates, separator: " OR ", empty: "1 = 0", binder: &binder)

        case let .not(predicate):
            return "(NOT (\(try render(predicate, binder: &binder))))"
        }
    }

    private func renderGroup(
        _ predicates: [SQLPredicate],
        separator: String,
        empty: String,
        binder: inout ParamBinder
    ) throws -> String {
        guard !predicates.isEmpty else { return empty }

        var rendered: [String] = []
        rendered.reserveCapacity(predicates.count)
        for predicate in predicates {
            rendered.append(try render(predicate, binder: &binder))
        }
        return "(\(rendered.joined(separator: separator)))"
    }

    private func validateTable(_ table: String) throws {
        guard !table.isEmpty else { throw SQLRenderError.emptyTable }
        guard !table.utf8.contains(0) else {
            throw SQLRenderError.identifierContainsNullByte
        }
    }

    private func validateColumn(_ column: String) throws {
        guard !column.isEmpty else { throw SQLRenderError.emptyColumn }
        guard !column.utf8.contains(0) else {
            throw SQLRenderError.identifierContainsNullByte
        }
    }

    private func validatePagination(limit: Int?, offset: Int?) throws {
        if let limit, limit < 0 {
            throw SQLRenderError.negativeLimit(limit)
        }
        if let offset, offset < 0 {
            throw SQLRenderError.negativeOffset(offset)
        }
        if limit == nil, offset != nil {
            throw SQLRenderError.offsetRequiresLimit
        }
    }
}

private extension ComparisonOp {
    var sql: String {
        switch self {
        case .eq: "="
        case .neq: "<>"
        case .lt: "<"
        case .lte: "<="
        case .gt: ">"
        case .gte: ">="
        case .like: "LIKE"
        }
    }
}
