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

/// One target column and its bound value in a DML statement.
public struct SQLColumnValue: Sendable, Hashable {
    public let column: String
    public let value: SQLValue

    public init(column: String, value: SQLValue) {
        self.column = column
        self.value = value
    }
}

/// A single-row INSERT. An empty value list renders as `DEFAULT VALUES`.
public struct SQLInsert: Sendable, Hashable {
    public let table: String
    public let values: [SQLColumnValue]
    public let returning: [String]

    public init(
        table: String,
        values: [SQLColumnValue],
        returning: [String] = []
    ) {
        self.table = table
        self.values = values
        self.returning = returning
    }
}

/// A single-table UPDATE. A missing predicate intentionally targets every row.
public struct SQLUpdate: Sendable, Hashable {
    public let table: String
    public let assignments: [SQLColumnValue]
    public let predicate: SQLPredicate?
    public let returning: [String]

    public init(
        table: String,
        assignments: [SQLColumnValue],
        predicate: SQLPredicate?,
        returning: [String] = []
    ) {
        self.table = table
        self.assignments = assignments
        self.predicate = predicate
        self.returning = returning
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
    case duplicateInsertColumn(String)
    case noUpdatedColumns
    case duplicateUpdateColumn(String)
    case returningUnsupported
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

    public func render(_ insert: SQLInsert) throws -> RenderedSQL {
        try validateTable(insert.table)

        var insertedColumns: Set<String> = []
        for value in insert.values {
            try validateColumn(value.column)
            guard insertedColumns.insert(value.column.lowercased()).inserted else {
                throw SQLRenderError.duplicateInsertColumn(value.column)
            }
        }
        let returningPlan = try returningPlan(for: insert.returning) {
            try dialect.insertReturningPlan(columns: $0)
        }

        var binder = ParamBinder(dialect: dialect)
        var sql = "INSERT INTO \(dialect.quoteIdentifier(insert.table))"

        if !insert.values.isEmpty {
            let columns = insert.values
                .map { dialect.quoteIdentifier($0.column) }
                .joined(separator: ", ")
            sql += " (\(columns))"
        }

        if let returningPlan, returningPlan.placement == .embedded {
            sql += " " + render(returningPlan)
        }

        if insert.values.isEmpty {
            sql += " DEFAULT VALUES"
        } else {
            let placeholders = insert.values
                .map { binder.bind($0.value) }
                .joined(separator: ", ")
            sql += " VALUES (\(placeholders))"
        }

        if let returningPlan, returningPlan.placement == .suffix {
            sql += " " + render(returningPlan)
        }

        return RenderedSQL(sql: sql, parameters: binder.parameters)
    }

    public func render(_ update: SQLUpdate) throws -> RenderedSQL {
        try validateTable(update.table)
        guard !update.assignments.isEmpty else {
            throw SQLRenderError.noUpdatedColumns
        }

        var updatedColumns: Set<String> = []
        for assignment in update.assignments {
            try validateColumn(assignment.column)
            guard updatedColumns.insert(assignment.column.lowercased()).inserted else {
                throw SQLRenderError.duplicateUpdateColumn(assignment.column)
            }
        }
        let returningPlan = try returningPlan(for: update.returning) {
            try dialect.updateReturningPlan(columns: $0)
        }

        var binder = ParamBinder(dialect: dialect)
        let assignments = update.assignments.map { assignment in
            "\(dialect.quoteIdentifier(assignment.column)) = \(binder.bind(assignment.value))"
        }
        var sql = "UPDATE \(dialect.quoteIdentifier(update.table)) "
            + "SET \(assignments.joined(separator: ", "))"

        if let returningPlan, returningPlan.placement == .embedded {
            sql += " " + render(returningPlan)
        }

        if let predicate = update.predicate {
            sql += " WHERE \(try render(predicate, binder: &binder))"
        }

        if let returningPlan, returningPlan.placement == .suffix {
            sql += " " + render(returningPlan)
        }

        return RenderedSQL(sql: sql, parameters: binder.parameters)
    }

    private func returningPlan(
        for columns: [String],
        using makePlan: ([String]) throws -> SQLDMLReturningPlan?
    ) throws -> SQLDMLReturningPlan? {
        try columns.forEach(validateColumn)
        guard !columns.isEmpty else { return nil }
        guard dialect.capabilities.contains(.returning),
              let plan = try makePlan(columns)
        else {
            throw SQLRenderError.returningUnsupported
        }
        return plan
    }

    private func render(_ returning: SQLDMLReturningPlan) -> String {
        returning.fragments.map { fragment in
            switch fragment {
            case let .literal(sql):
                sql
            case let .column(column):
                dialect.quoteIdentifier(column)
            }
        }.joined()
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
