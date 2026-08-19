/// Accumulates parameters while a renderer emits placeholders in one deterministic pass.
public struct ParamBinder: Sendable {
    /// The dialect that supplies placeholders for appended parameters.
    public let dialect: any SQLDialect
    /// Parameters accumulated in lexical placeholder order.
    public private(set) var parameters: [SQLValue]

    /// Creates a binder, optionally continuing after an existing parameter prefix.
    public init(dialect: any SQLDialect, parameters: [SQLValue] = []) {
        self.dialect = dialect
        self.parameters = parameters
    }

    /// Appends `value` and returns its one-based dialect placeholder.
    public mutating func bind(_ value: SQLValue) -> String {
        parameters.append(value)
        return dialect.placeholder(at: parameters.count)
    }
}
