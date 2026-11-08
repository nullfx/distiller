import Foundation

/// A condition such as "<16", ">=24" or "27" (meaning == 27), used in overlay `when` blocks.
/// Operands are compared as dotted versions, so it works for memory, GPU cores and macOS versions.
public struct Comparison: Codable, Equatable, Sendable, CustomStringConvertible {
    public enum Operator: String, Sendable {
        case lessThan = "<"
        case lessOrEqual = "<="
        case greaterThan = ">"
        case greaterOrEqual = ">="
        case equal = "=="
    }

    public var op: Operator
    public var operand: String

    public init(_ op: Operator, _ operand: String) {
        self.op = op
        self.operand = operand
    }

    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let symbol = ["<=", ">=", "==", "<", ">"].first { trimmed.hasPrefix($0) }
        self.op = symbol.flatMap(Operator.init(rawValue:)) ?? .equal
        self.operand = String(trimmed.dropFirst(symbol?.count ?? 0)).trimmingCharacters(in: .whitespaces)
        guard !operand.isEmpty, operand.allSatisfy({ $0.isNumber || $0 == "." }) else {
            throw DistillerError.invalidRecipe("\"\(text)\" isn't a comparison. Use a number with an optional <, <=, >, >= or == in front, such as \"<16\".")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            try self.init(parsing: String(number))
        } else if let number = try? container.decode(Double.self) {
            try self.init(parsing: String(number))
        } else {
            try self.init(parsing: try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        op == .equal ? operand : "\(op.rawValue)\(operand)"
    }

    public func matches(_ value: VersionNumber) -> Bool {
        let rhs = VersionNumber(operand)
        switch op {
        case .lessThan: return value < rhs
        case .lessOrEqual: return value <= rhs
        case .greaterThan: return value > rhs
        case .greaterOrEqual: return value >= rhs
        case .equal: return value == rhs
        }
    }

    public func matches(_ value: Int) -> Bool {
        matches(VersionNumber(String(value)))
    }
}
