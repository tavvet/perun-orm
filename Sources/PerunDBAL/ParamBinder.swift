/// Accumulates parameters while a renderer emits placeholders in one deterministic pass.
public struct ParamBinder: Sendable {
    public let dialect: any SQLDialect
    public private(set) var parameters: [SQLValue]

    public init(dialect: any SQLDialect, parameters: [SQLValue] = []) {
        self.dialect = dialect
        self.parameters = parameters
    }

    public mutating func bind(_ value: SQLValue) -> String {
        parameters.append(value)
        return dialect.placeholder(at: parameters.count)
    }
}
