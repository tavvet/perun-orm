/// One rendered statement and its positional bind values.
public struct RenderedSQL: Sendable, Hashable {
    /// The rendered statement with backend placeholders.
    public let sql: String
    /// Bind values in lexical placeholder order.
    public let parameters: [SQLValue]

    /// Creates a rendered statement and its ordered bind values.
    public init(sql: String, parameters: [SQLValue]) {
        self.sql = sql
        self.parameters = parameters
    }
}

/// Portable comparison operators supported by ``SQLPredicate``.
public enum ComparisonOp: Sendable, Hashable {
    /// Equality (`=`), rewritten to `IS NULL` for a null value.
    case eq
    /// Inequality (`<>`), rewritten to `IS NOT NULL` for a null value.
    case neq
    /// Strictly less than (`<`).
    case lt
    /// Less than or equal (`<=`).
    case lte
    /// Strictly greater than (`>`).
    case gt
    /// Greater than or equal (`>=`).
    case gte
    /// SQL pattern matching (`LIKE`).
    case like
}

/// A backend-neutral predicate over one table. Column names are identifiers, never SQL fragments.
public indirect enum SQLPredicate: Sendable, Hashable {
    /// Compares one column with one bound semantic value.
    case comparison(column: String, op: ComparisonOp, value: SQLValue)
    /// Tests membership in a list of bound values.
    case inList(column: String, values: [SQLValue])
    /// Tests whether a column is null, optionally negating the test.
    case null(column: String, negated: Bool)
    /// Combines predicates with logical AND; an empty group is true.
    case and([SQLPredicate])
    /// Combines predicates with logical OR; an empty group is false.
    case or([SQLPredicate])
    /// Negates one predicate.
    case not(SQLPredicate)
}

/// Sort direction for one SQL ordering.
public enum SQLSortDirection: Sendable, Hashable {
    /// Ascending order (`ASC`).
    case ascending
    /// Descending order (`DESC`).
    case descending
}

/// One identifier-only ordering in a portable SELECT.
public struct SQLOrdering: Sendable, Hashable {
    /// The unquoted column identifier.
    public let column: String
    /// The direction applied to the column.
    public let direction: SQLSortDirection

    /// Creates an ordering for one unquoted column identifier.
    public init(column: String, direction: SQLSortDirection = .ascending) {
        self.column = column
        self.direction = direction
    }
}

/// A single-table SELECT. Projections and orderings are identifier-only in the v0.1 slice.
public struct SQLSelect: Sendable, Hashable {
    /// The unquoted table identifier.
    public let table: String
    /// Unquoted projected column identifiers in result order.
    public let columns: [String]
    /// The optional row predicate.
    public let predicate: SQLPredicate?
    /// Ordered sort terms.
    public let orderings: [SQLOrdering]
    /// The optional nonnegative row limit, validated during rendering.
    public let limit: Int?
    /// The optional nonnegative row offset, valid only with a limit.
    public let offset: Int?

    /// Creates a portable single-table SELECT description.
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

/// A filtered `COUNT(*)` query. Ordering and pagination are intentionally not represented.
public struct SQLCount: Sendable, Hashable {
    /// Stable result-column alias expected by DBAL and ORM count decoders.
    public static let resultColumn = "count"

    /// The unquoted table identifier.
    public let table: String
    /// The optional row predicate.
    public let predicate: SQLPredicate?

    /// Creates a portable filtered `COUNT(*)` description.
    public init(table: String, predicate: SQLPredicate? = nil) {
        self.table = table
        self.predicate = predicate
    }
}

/// One target column and its bound value in a DML statement.
public struct SQLColumnValue: Sendable, Hashable {
    /// The unquoted target column identifier.
    public let column: String
    /// The semantic value bound for the column.
    public let value: SQLValue

    /// Creates one column/value pair for INSERT or UPDATE.
    public init(column: String, value: SQLValue) {
        self.column = column
        self.value = value
    }
}

/// A single-row INSERT. An empty value list renders as `DEFAULT VALUES`.
public struct SQLInsert: Sendable, Hashable {
    /// The unquoted target table identifier.
    public let table: String
    /// Inserted columns and values in bind order.
    public let values: [SQLColumnValue]
    /// Unquoted columns requested from a row-returning clause.
    public let returning: [String]

    /// Creates a portable single-row INSERT description.
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
    /// The unquoted target table identifier.
    public let table: String
    /// Assigned columns and values in bind order.
    public let assignments: [SQLColumnValue]
    /// The optional row predicate; `nil` explicitly targets every row.
    public let predicate: SQLPredicate?
    /// Unquoted columns requested from a row-returning clause.
    public let returning: [String]

    /// Creates a portable UPDATE description.
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

/// A single-table DELETE. The predicate argument is required; explicit `nil` targets every row.
public struct SQLDelete: Sendable, Hashable {
    /// The unquoted target table identifier.
    public let table: String
    /// The optional row predicate; `nil` explicitly targets every row.
    public let predicate: SQLPredicate?
    /// Unquoted columns requested from a row-returning clause.
    public let returning: [String]

    /// Creates a portable DELETE description.
    public init(
        table: String,
        predicate: SQLPredicate?,
        returning: [String] = []
    ) {
        self.table = table
        self.predicate = predicate
        self.returning = returning
    }
}

/// Structural role of one portable table column.
public enum SQLColumnRole: Sendable, Hashable {
    /// A regular mapped attribute.
    case attribute
    /// The table primary key, optionally generated by the backend.
    case primaryKey(generated: Bool)
}

/// One portable column definition in a CREATE TABLE statement.
public struct SQLColumnDefinition: Sendable, Hashable {
    /// The unquoted column identifier.
    public let name: String
    /// The portable column type.
    public let type: ColumnType
    /// Whether generated DDL permits SQL `NULL`.
    public let isNullable: Bool
    /// Whether generated DDL adds a column-level uniqueness constraint.
    public let isUnique: Bool
    /// The structural role of the column.
    public let role: SQLColumnRole

    /// Creates one portable CREATE TABLE column definition.
    public init(
        name: String,
        type: ColumnType,
        nullable: Bool = false,
        unique: Bool = false,
        role: SQLColumnRole = .attribute
    ) {
        self.name = name
        self.type = type
        isNullable = nullable
        isUnique = unique
        self.role = role
    }
}

/// A portable CREATE TABLE with column-level constraints only.
public struct SQLCreateTable: Sendable, Hashable {
    /// The unquoted table identifier.
    public let table: String
    /// Column definitions in declaration order.
    public let columns: [SQLColumnDefinition]

    /// Creates a portable CREATE TABLE description.
    public init(table: String, columns: [SQLColumnDefinition]) {
        self.table = table
        self.columns = columns
    }
}

/// Structural validation failures reported before SQL is returned to an executor.
public enum SQLRenderError: Error, Sendable, Equatable {
    /// The table identifier is empty.
    case emptyTable
    /// A SELECT projection contains no columns.
    case noSelectedColumns
    /// A column identifier is empty.
    case emptyColumn
    /// An identifier contains a null byte.
    case identifierContainsNullByte
    /// An ordered or pattern comparison was given SQL `NULL`.
    case nullComparison(ComparisonOp)
    /// A SELECT limit is negative.
    case negativeLimit(Int)
    /// A SELECT offset is negative.
    case negativeOffset(Int)
    /// An offset was supplied without a limit.
    case offsetRequiresLimit
    /// An INSERT names the same column more than once, ignoring case.
    case duplicateInsertColumn(String)
    /// An UPDATE contains no assignments.
    case noUpdatedColumns
    /// An UPDATE assigns the same column more than once, ignoring case.
    case duplicateUpdateColumn(String)
    /// Returning columns were requested from a dialect without a returning plan.
    case returningUnsupported
    /// A CREATE TABLE statement contains no columns.
    case noTableColumns
    /// A CREATE TABLE statement repeats a column name, ignoring case.
    case duplicateTableColumn(String)
    /// A CREATE TABLE statement declares more than one primary key column.
    case multiplePrimaryKeys
    /// A primary key column was declared nullable.
    case nullablePrimaryKey(String)
    /// A generated primary key uses a portable type other than `Int64`.
    case generatedPrimaryKeyRequiresInt64(column: String, actual: ColumnType)
}

/// Pure renderer: it never executes SQL and owns no mutable state between calls.
public struct SQLRenderer: Sendable {
    /// The backend policy used for quoting, placeholders, types, and grammar placement.
    public let dialect: any SQLDialect

    /// Creates a stateless renderer for `dialect`.
    public init(dialect: any SQLDialect) {
        self.dialect = dialect
    }

    /// Validates and renders a portable SELECT.
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

    /// Validates and renders a portable `COUNT(*)` SELECT.
    public func render(_ count: SQLCount) throws -> RenderedSQL {
        try validateTable(count.table)

        var binder = ParamBinder(dialect: dialect)
        var sql = "SELECT COUNT(*) AS \(dialect.quoteIdentifier(SQLCount.resultColumn)) "
            + "FROM \(dialect.quoteIdentifier(count.table))"
        if let predicate = count.predicate {
            sql += " WHERE \(try render(predicate, binder: &binder))"
        }
        return RenderedSQL(sql: sql, parameters: binder.parameters)
    }

    /// Validates and renders a single-row INSERT.
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

    /// Validates and renders an UPDATE.
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

    /// Validates and renders a DELETE.
    public func render(_ delete: SQLDelete) throws -> RenderedSQL {
        try validateTable(delete.table)
        let returningPlan = try returningPlan(for: delete.returning) {
            try dialect.deleteReturningPlan(columns: $0)
        }

        var binder = ParamBinder(dialect: dialect)
        var sql = "DELETE FROM \(dialect.quoteIdentifier(delete.table))"

        if let returningPlan, returningPlan.placement == .embedded {
            sql += " " + render(returningPlan)
        }

        if let predicate = delete.predicate {
            sql += " WHERE \(try render(predicate, binder: &binder))"
        }

        if let returningPlan, returningPlan.placement == .suffix {
            sql += " " + render(returningPlan)
        }

        return RenderedSQL(sql: sql, parameters: binder.parameters)
    }

    /// Validates and renders a portable CREATE TABLE statement.
    public func render(_ createTable: SQLCreateTable) throws -> RenderedSQL {
        try validateTable(createTable.table)
        guard !createTable.columns.isEmpty else {
            throw SQLRenderError.noTableColumns
        }

        var columnNames: Set<String> = []
        var primaryKeyCount = 0
        for column in createTable.columns {
            try validateColumn(column.name)
            guard columnNames.insert(column.name.lowercased()).inserted else {
                throw SQLRenderError.duplicateTableColumn(column.name)
            }
            guard case let .primaryKey(generated) = column.role else { continue }
            primaryKeyCount += 1
            guard primaryKeyCount == 1 else {
                throw SQLRenderError.multiplePrimaryKeys
            }
            guard !column.isNullable else {
                throw SQLRenderError.nullablePrimaryKey(column.name)
            }
            if generated, column.type != .int64 {
                throw SQLRenderError.generatedPrimaryKeyRequiresInt64(
                    column: column.name,
                    actual: column.type
                )
            }
        }

        let columns = createTable.columns.map(renderColumnDefinition)
        let sql = "CREATE TABLE \(dialect.quoteIdentifier(createTable.table)) "
            + "(\(columns.joined(separator: ", ")))"
        return RenderedSQL(sql: sql, parameters: [])
    }

    private func renderColumnDefinition(_ column: SQLColumnDefinition) -> String {
        if case .primaryKey(generated: true) = column.role {
            var sql = dialect.renderGeneratedPrimaryKeyColumn(column.name)
            if column.isUnique {
                sql += " UNIQUE"
            }
            return sql
        }

        var fragments = [
            dialect.quoteIdentifier(column.name),
            dialect.renderColumnType(column.type),
        ]
        if !column.isNullable {
            fragments.append("NOT NULL")
        }
        if case .primaryKey = column.role {
            fragments.append("PRIMARY KEY")
        }
        if column.isUnique {
            fragments.append("UNIQUE")
        }
        return fragments.joined(separator: " ")
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
