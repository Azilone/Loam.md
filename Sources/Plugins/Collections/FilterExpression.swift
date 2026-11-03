import Foundation

/// One expression of a `.base` filter (`file.inFolder("Projects")`, `status != "done" && priority > 2`), parsed.
/// The subset of Obsidian's language Loam reads: literals, property and file references, `.`, `[ ]`, calls,
/// `! - + * / %`, comparisons, `&&` and `||`. What it cannot parse is reported, never rewritten.
indirect enum FilterExpression: Equatable {
    case literal(FilterValue)
    case identifier(String)
    case member(FilterExpression, String)
    case index(FilterExpression, FilterExpression)
    case call(FilterExpression, [FilterExpression])
    case unary(String, FilterExpression)
    case binary(String, FilterExpression, FilterExpression)

    struct ParseError: Error, Equatable {
        let message: String
    }

    static func parse(_ text: String) throws -> FilterExpression {
        var parser = Parser(tokens: try tokenize(text))
        let expression = try parser.expression(0)
        guard parser.peek == nil else { throw ParseError(message: "unexpected \(parser.peek!) in \(text)") }
        return expression
    }

    // MARK: Tokens

    enum Token: Equatable, CustomStringConvertible {
        case number(Double), string(String), name(String), symbol(String)

        var description: String {
            switch self {
            case .number(let number): return String(number)
            case .string(let text): return "\"\(text)\""
            case .name(let name): return name
            case .symbol(let symbol): return symbol
            }
        }
    }

    private static let symbols = ["==", "!=", "<=", ">=", "&&", "||", "<", ">", "!", "+", "-", "*", "/", "%",
                                  "(", ")", "[", "]", ".", ","]

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character == "\"" || character == "'" {
                var value = ""
                index += 1
                while index < characters.count, characters[index] != character {
                    if characters[index] == "\\", index + 1 < characters.count {
                        index += 1
                        switch characters[index] {
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        default: value.append(characters[index])
                        }
                    } else {
                        value.append(characters[index])
                    }
                    index += 1
                }
                guard index < characters.count else { throw ParseError(message: "unclosed string in \(text)") }
                index += 1
                tokens.append(.string(value))
            } else if character.isNumber {
                var end = index
                while end < characters.count, characters[end].isNumber || characters[end] == "." { end += 1 }
                guard let number = Double(String(characters[index..<end])) else {
                    throw ParseError(message: "bad number in \(text)")
                }
                tokens.append(.number(number))
                index = end
            } else if character.isLetter || character == "_" || character == "$" {
                var end = index
                while end < characters.count, characters[end].isLetter || characters[end].isNumber
                    || characters[end] == "_" || characters[end] == "$" { end += 1 }
                tokens.append(.name(String(characters[index..<end])))
                index = end
            } else if let symbol = symbols.first(where: { symbol in
                symbol.count <= characters.count - index && String(characters[index..<index + symbol.count]) == symbol
            }) {
                tokens.append(.symbol(symbol))
                index += symbol.count
            } else {
                throw ParseError(message: "unexpected \(character) in \(text)")
            }
        }
        return tokens
    }

    // MARK: Parser (precedence climbing)

    private struct Parser {
        let tokens: [Token]
        var position = 0

        var peek: Token? { position < tokens.count ? tokens[position] : nil }

        mutating func next() -> Token? {
            defer { position += 1 }
            return peek
        }

        mutating func expect(_ symbol: String) throws {
            guard next() == .symbol(symbol) else { throw ParseError(message: "expected \(symbol)") }
        }

        private static let precedence: [String: Int] = [
            "||": 1, "&&": 2, "==": 3, "!=": 3, "<": 4, "<=": 4, ">": 4, ">=": 4, "+": 5, "-": 5, "*": 6, "/": 6, "%": 6,
        ]

        mutating func expression(_ minimum: Int) throws -> FilterExpression {
            var left = try unary()
            while case .symbol(let symbol)? = peek, let level = Self.precedence[symbol], level > minimum {
                position += 1
                left = .binary(symbol, left, try expression(level))
            }
            return left
        }

        mutating func unary() throws -> FilterExpression {
            if case .symbol(let symbol)? = peek, symbol == "!" || symbol == "-" {
                position += 1
                return .unary(symbol, try unary())
            }
            return try postfix(try primary())
        }

        mutating func primary() throws -> FilterExpression {
            switch next() {
            case .number(let number)?: return .literal(.number(number))
            case .string(let text)?: return .literal(.string(text))
            case .name("true")?: return .literal(.bool(true))
            case .name("false")?: return .literal(.bool(false))
            case .name("null")?: return .literal(.null)
            case .name(let name)?: return .identifier(name)
            case .symbol("(")?:
                let inner = try expression(0)
                try expect(")")
                return inner
            case .symbol("[")?:
                var items: [FilterExpression] = []
                if peek != .symbol("]") {
                    repeat { items.append(try expression(0)) } while try comma()
                }
                try expect("]")
                return .call(.identifier("$list"), items)
            case let token?: throw ParseError(message: "unexpected \(token)")
            case nil: throw ParseError(message: "unexpected end")
            }
        }

        mutating func comma() throws -> Bool {
            guard peek == .symbol(",") else { return false }
            position += 1
            return true
        }

        mutating func postfix(_ base: FilterExpression) throws -> FilterExpression {
            var expression = base
            while true {
                switch peek {
                case .symbol(".")?:
                    position += 1
                    guard case .name(let name)? = next() else { throw ParseError(message: "expected a name after .") }
                    expression = .member(expression, name)
                case .symbol("[")?:
                    position += 1
                    let index = try self.expression(0)
                    try expect("]")
                    expression = .index(expression, index)
                case .symbol("(")?:
                    position += 1
                    var arguments: [FilterExpression] = []
                    if peek != .symbol(")") {
                        repeat { arguments.append(try self.expression(0)) } while try comma()
                    }
                    try expect(")")
                    expression = .call(expression, arguments)
                default:
                    return expression
                }
            }
        }
    }
}
