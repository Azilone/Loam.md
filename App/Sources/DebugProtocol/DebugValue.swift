import Foundation

/// A JSON value, for the debug channel's free-form parameters and results. Foundation only.
public enum DebugValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DebugValue])
    case object([String: DebugValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DebugValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: DebugValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var double: Double? { if case .number(let value) = self { value } else { nil } }
    public var int: Int? { double.map { Int($0) } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var array: [DebugValue]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: DebugValue]? { if case .object(let value) = self { value } else { nil } }

    public subscript(key: String) -> DebugValue? { object?[key] }
}

extension DebugValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: DebugValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, DebugValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}
