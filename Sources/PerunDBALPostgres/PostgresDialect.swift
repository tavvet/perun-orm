import PerunDBAL

/// PostgreSQL rendering policy.
public struct PostgresDialect: SQLDialect {
    public let capabilities: DialectCapabilities = [
        .returning,
        .nativeBoolean,
        .nativeTimestamp,
        .nativeUUID,
    ]

    public init() {}

    public func placeholder(at position: Int) -> String {
        precondition(position > 0, "placeholder positions are one-based")
        return "$\(position)"
    }

    public func paginationPlan(
        limit: Int,
        offset: Int?,
        context: SQLPaginationContext
    ) -> SQLPaginationPlan {
        var fragments: [SQLPaginationFragment] = [
            .literal("LIMIT "),
            .parameter(limit),
        ]
        if let offset {
            fragments.append(contentsOf: [
                .literal(" OFFSET "),
                .parameter(offset),
            ])
        }
        return SQLPaginationPlan(placement: .suffix, fragments: fragments)
    }

    public func insertReturningPlan(columns: [String]) -> SQLDMLReturningPlan? {
        returningPlan(columns: columns)
    }

    public func updateReturningPlan(columns: [String]) -> SQLDMLReturningPlan? {
        returningPlan(columns: columns)
    }

    private func returningPlan(columns: [String]) -> SQLDMLReturningPlan {
        var fragments: [SQLDMLReturningFragment] = [.literal("RETURNING ")]
        for (index, column) in columns.enumerated() {
            if index > 0 {
                fragments.append(.literal(", "))
            }
            fragments.append(.column(column))
        }
        return SQLDMLReturningPlan(placement: .suffix, fragments: fragments)
    }
}
