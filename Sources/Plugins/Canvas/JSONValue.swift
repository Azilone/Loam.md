import Foundation

/// A JSON value that keeps the order of an object's keys, so a board's unknown fields (another app's extensions)
/// are written back where they were. `JSONDecoder` loses that order and cannot tell `true` from `1` everywhere.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case let .object(pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }
}

public enum JSONParseError: Error, Equatable {
    case unexpected(offset: Int)
    case endOfInput
}

// MARK: - Reading

extension JSONValue {
    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipSpace()
        let value = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw JSONParseError.unexpected(offset: parser.index) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        func peek() throws -> UInt8 {
            guard index < bytes.count else { throw JSONParseError.endOfInput }
            return bytes[index]
        }

        mutating func expect(_ literal: String) throws {
            for byte in literal.utf8 {
                guard try peek() == byte else { throw JSONParseError.unexpected(offset: index) }
                index += 1
            }
        }

        mutating func value() throws -> JSONValue {
            switch try peek() {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func object() throws -> JSONValue {
            index += 1
            var pairs: [(key: String, value: JSONValue)] = []
            skipSpace()
            if try peek() == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while true {
                skipSpace()
                guard try peek() == UInt8(ascii: "\"") else { throw JSONParseError.unexpected(offset: index) }
                let key = try string()
                skipSpace()
                try expect(":")
                skipSpace()
                let value = try value()
                if let existing = pairs.firstIndex(where: { $0.key == key }) {
                    pairs[existing].value = value
                } else {
                    pairs.append((key, value))
                }
                skipSpace()
                switch try peek() {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "}"): index += 1; return .object(pairs)
                default: throw JSONParseError.unexpected(offset: index)
                }
            }
        }

        mutating func array() throws -> JSONValue {
            index += 1
            var items: [JSONValue] = []
            skipSpace()
            if try peek() == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipSpace()
                items.append(try value())
                skipSpace()
                switch try peek() {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "]"): index += 1; return .array(items)
                default: throw JSONParseError.unexpected(offset: index)
                }
            }
        }

        mutating func string() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var start = index
            func flush(_ end: Int) {
                guard end > start else { return }
                scalars.append(contentsOf: String(decoding: bytes[start..<end], as: UTF8.self).unicodeScalars)
            }
            while true {
                let byte = try peek()
                switch byte {
                case UInt8(ascii: "\""):
                    flush(index)
                    index += 1
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    flush(index)
                    index += 1
                    let escape = try peek()
                    index += 1
                    switch escape {
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800..<0xDC00).contains(code), index + 1 < bytes.count,
                           bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default: scalars.append(Unicode.Scalar(escape))
                    }
                    start = index
                default:
                    index += 1
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
            else { throw JSONParseError.unexpected(offset: index) }
            index += 4
            return code
        }

        mutating func number() throws -> Double {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                throw JSONParseError.unexpected(offset: start)
            }
            return value
        }
    }
}

// MARK: - Writing

extension JSONValue {
    /// Compact JSON on one line, keys in their order. Whole numbers are written without a fraction.
    public var compact: String {
        var out = ""
        write(to: &out)
        return out
    }

    func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(value): out += value ? "true" : "false"
        case let .number(value): out += JSONValue.format(value)
        case let .string(value): JSONValue.quote(value, into: &out)
        case let .array(items):
            out += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 { out += "," }
                item.write(to: &out)
            }
            out += "]"
        case let .object(pairs):
            out += "{"
            for (offset, pair) in pairs.enumerated() {
                if offset > 0 { out += "," }
                JSONValue.quote(pair.key, into: &out)
                out += ":"
                pair.value.write(to: &out)
            }
            out += "}"
        }
    }

    static func format(_ number: Double) -> String {
        if number.isFinite, number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        return number.isFinite ? "\(number)" : "0"
    }

    static func quote(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let control where control.value < 0x20:
                out += String(format: "\\u%04x", control.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
