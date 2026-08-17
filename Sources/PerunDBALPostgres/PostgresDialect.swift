import PerunDBAL

/// PostgreSQL rendering policy. The executor joins this target after the two driver manifests
/// have globally unique auxiliary target names and SwiftPM can load both packages together.
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
