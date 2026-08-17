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
}
