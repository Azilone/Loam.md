import Foundation
import PluginKit

/// A value while a filter is evaluated. `unknown` is what Loam cannot compute (a formula, `file.hasLink`): it spreads
/// through the expression, and an entry whose filter ends unknown is shown.
enum FilterValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case list([FilterValue])
    case object([String: FilterValue])
    case file(FileFacts)
    case unknown(String)

    init(_ value: PropertyValue?) {
        switch value {
        case nil, .null?: self = .null
        case .bool(let flag)?: self = .bool(flag)
        case .number(let number)?: self = .number(number)
        case .string(let text)?: self = .string(text)
        case .list(let items)?: self = .list(items.map { FilterValue($0) })
        case .map(let map)?: self = .object(map.mapValues { FilterValue($0) })
        }
    }

    /// The value as a property value, nil for files and unknowns.
    var property: PropertyValue? {
        switch self {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .number(let number): return .number(number)
        case .string(let text): return .string(text)
        case .list(let items):
            var values: [PropertyValue] = []
            for item in items {
                guard let value = item.property else { return nil }
                values.append(value)
            }
            return .list(values)
        case .object(let map):
            var values: [String: PropertyValue] = [:]
            for (key, item) in map {
                guard let value = item.property else { return nil }
                values[key] = value
            }
            return .map(values)
        case .file(let facts): return .string(facts.path)
        case .unknown: return nil
        }
    }
}

/// What a filter knows about a file: its path parts, tags, properties and modification time.
struct FileFacts: Equatable {
    let path: String
    let tags: [String]
    let properties: [String: PropertyValue]
    let modified: Double

    init(path: String, tags: [String], properties: [String: PropertyValue], modified: Double) {
        self.path = path
        self.tags = tags
        self.properties = properties
        self.modified = modified
    }

    init(_ record: NoteRecord) {
        self.init(path: record.path, tags: record.tags, properties: record.properties, modified: record.modified)
    }

    var name: String { String(path.split(separator: "/").last ?? "") }
    var folder: String { VaultPath.directory(of: path) }
    var ext: String { name.contains(".") ? String(name.split(separator: ".").last!).lowercased() : "" }
    var basename: String { ext.isEmpty ? name : String(name.dropLast(ext.count + 1)) }

    func inFolder(_ folder: String) -> Bool {
        let folder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return folder.isEmpty || path.hasPrefix(folder + "/")
    }

    /// Any of the tags, without `#`, ignoring case; a nested tag counts for its parent.
    func hasTag(_ wanted: [String]) -> Bool {
        wanted.contains { want in
            let want = (want.hasPrefix("#") ? String(want.dropFirst()) : want).lowercased()
            return tags.contains { tag in
                let tag = tag.lowercased()
                return tag == want || tag.hasPrefix(want + "/")
            }
        }
    }
}

/// A filter as written under `filters:`: an expression, or `and` / `or` / `not` of filters (`not`: none is true).
indirect enum FilterTree: Equatable {
    case expression(String)
    case and([FilterTree])
    case or([FilterTree])
    case not([FilterTree])
}

/// Evaluates filters for one entry. `host` is `this`: the note holding a ` ```base ` block, or the `.base` file.
struct FilterEvaluator {
    let entry: FileFacts
    let host: FileFacts?
    /// Why some values were unknown, gathered for the collection's warnings.
    private(set) var unknowns: Set<String> = []

    init(entry: FileFacts, host: FileFacts?) {
        self.entry = entry
        self.host = host
    }

    /// true or false, nil when unknown.
    mutating func matches(_ tree: FilterTree) -> Bool? {
        switch tree {
        case .expression(let text):
            do {
                return truth(evaluate(try FilterExpression.parse(text)))
            } catch {
                unknowns.insert("cannot read the filter \(text)")
                return nil
            }
        case .and(let items):
            var result: Bool? = true
            for item in items {
                switch matches(item) {
                case false?: return false
                case nil: result = nil
                case true?: continue
                }
            }
            return result
        case .or(let items):
            var result: Bool? = false
            for item in items {
                switch matches(item) {
                case true?: return true
                case nil: result = nil
                case false?: continue
                }
            }
            return result
        case .not(let items):
            return matches(.or(items)).map { !$0 }
        }
    }

    func truth(_ value: FilterValue) -> Bool? {
        switch value {
        case .null: return false
        case .bool(let flag): return flag
        case .number(let number): return number != 0
        case .string(let text): return !text.isEmpty
        case .list(let items): return !items.isEmpty
        case .object, .file: return true
        case .unknown: return nil
        }
    }

    mutating func evaluate(_ expression: FilterExpression) -> FilterValue {
        switch expression {
        case .literal(let value):
            return value
        case .identifier(let name):
            switch name {
            case "file": return .file(entry)
            case "note": return .object(entry.properties.mapValues { FilterValue($0) })
            case "this":
                guard let host else { return unknown("this outside a note") }
                return .object(["file": .file(host)].merging(host.properties.mapValues { FilterValue($0) }) { a, _ in a })
            case "formula": return unknown("formulas")
            default: return FilterValue(PropertyComparison.property(name, of: entry.properties))
            }
        case .member(let base, let name):
            return member(evaluate(base), name)
        case .index(let base, let index):
            guard case .string(let key) = evaluate(index) else { return unknown("an index that is not a name") }
            return member(evaluate(base), key)
        case .call(.identifier("$list"), let items):
            return .list(items.map { evaluate($0) })
        case .call(.member(let target, let method), let arguments):
            let target = evaluate(target)
            return call(method, on: target, arguments.map { evaluate($0) })
        case .call(.identifier(let function), _):
            return unknown("the function \(function)()")
        case .call:
            return unknown("a call Loam cannot read")
        case .unary(let op, let operand):
            let value = evaluate(operand)
            if case .unknown = value { return value }
            if op == "!" { return truth(value).map { .bool(!$0) } ?? value }
            guard case .number(let number) = value else { return .null }
            return .number(-number)
        case .binary("&&", let left, let right):
            let a = truth(evaluate(left))
            if a == false { return .bool(false) }
            let b = truth(evaluate(right))
            if b == false { return .bool(false) }
            return a == true && b == true ? .bool(true) : unknown(nil)
        case .binary("||", let left, let right):
            let a = truth(evaluate(left))
            if a == true { return .bool(true) }
            let b = truth(evaluate(right))
            if b == true { return .bool(true) }
            return a == false && b == false ? .bool(false) : unknown(nil)
        case .binary(let op, let left, let right):
            return binary(op, evaluate(left), evaluate(right))
        }
    }

    private mutating func unknown(_ reason: String?) -> FilterValue {
        if let reason { unknowns.insert(reason) }
        return .unknown(reason ?? "")
    }

    private mutating func member(_ base: FilterValue, _ name: String) -> FilterValue {
        switch base {
        case .unknown:
            return base
        case .object(let map):
            return map[name] ?? map.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? .null
        case .file(let facts):
            switch name {
            case "path": return .string(facts.path)
            case "name": return .string(facts.name)
            case "basename": return .string(facts.basename)
            case "folder": return .string(facts.folder)
            case "ext": return .string(facts.ext)
            case "tags": return .list(facts.tags.map { .string($0) })
            case "mtime": return .number(facts.modified * 1000)
            case "properties": return .object(facts.properties.mapValues { FilterValue($0) })
            default: return unknown("file.\(name)")
            }
        case .string(let text) where name == "length":
            return .number(Double(text.count))
        case .list(let items) where name == "length":
            return .number(Double(items.count))
        default:
            return .null
        }
    }

    private mutating func call(_ method: String, on target: FilterValue, _ arguments: [FilterValue]) -> FilterValue {
        if case .unknown = target { return target }
        if arguments.contains(where: { if case .unknown = $0 { return true } else { return false } }) {
            return unknown(nil)
        }
        let texts = arguments.compactMap { value -> String? in
            if case .string(let text) = value { return text }
            if case .file(let facts) = value { return facts.path }
            return nil
        }
        switch (target, method) {
        case (.file(let facts), "inFolder"):
            guard let folder = texts.first else { return unknown("file.inFolder without a folder") }
            return .bool(facts.inFolder(folder))
        case (.file(let facts), "hasTag"):
            return .bool(facts.hasTag(texts))
        case (.file(let facts), "hasProperty"):
            guard let name = texts.first else { return .bool(false) }
            return .bool(PropertyComparison.property(name, of: facts.properties).map { $0 != .null } ?? false)
        case (.file, _):
            return unknown("file.\(method)()")
        case (_, "isEmpty"):
            return .bool(truth(target) == false)
        case (.string(let text), "contains"):
            return .bool(texts.first.map { text.lowercased().contains($0.lowercased()) } ?? false)
        case (.string(let text), "startsWith"):
            return .bool(texts.first.map { text.lowercased().hasPrefix($0.lowercased()) } ?? false)
        case (.string(let text), "endsWith"):
            return .bool(texts.first.map { text.lowercased().hasSuffix($0.lowercased()) } ?? false)
        case (.string(let text), "lower"):
            return .string(text.lowercased())
        case (.string(let text), "upper"):
            return .string(text.uppercased())
        case (.list(let items), "contains"):
            return .bool(arguments.first.map { wanted in items.contains { equals($0, wanted) } } ?? false)
        case (.list(let items), "containsAny"):
            return .bool(arguments.contains { wanted in items.contains { equals($0, wanted) } })
        case (.list(let items), "containsAll"):
            return .bool(arguments.allSatisfy { wanted in items.contains { equals($0, wanted) } })
        case (.null, "contains"), (.null, "containsAny"), (.null, "containsAll"), (.null, "startsWith"),
             (.null, "endsWith"):
            return .bool(false)
        default:
            return unknown(".\(method)()")
        }
    }

    private func equals(_ a: FilterValue, _ b: FilterValue) -> Bool {
        guard let left = a.property, let right = b.property else { return false }
        return PropertyComparison.equals(left, right)
    }

    private mutating func binary(_ op: String, _ a: FilterValue, _ b: FilterValue) -> FilterValue {
        if case .unknown = a { return a }
        if case .unknown = b { return b }
        switch op {
        case "==": return .bool(equals(a, b))
        case "!=": return .bool(!equals(a, b))
        case "<", "<=", ">", ">=":
            guard let left = a.property, let right = b.property,
                  let order = PropertyComparison.order(left, right) else { return .bool(false) }
            switch op {
            case "<": return .bool(order == .orderedAscending)
            case "<=": return .bool(order != .orderedDescending)
            case ">": return .bool(order == .orderedDescending)
            default: return .bool(order != .orderedAscending)
            }
        case "+":
            if case .number(let x) = a, case .number(let y) = b { return .number(x + y) }
            if case .string(let x) = a, case .string(let y) = b { return .string(x + y) }
            return .null
        default:
            guard case .number(let x) = a, case .number(let y) = b else { return .null }
            switch op {
            case "-": return .number(x - y)
            case "*": return .number(x * y)
            case "/": return y == 0 ? .null : .number(x / y)
            default: return y == 0 ? .null : .number(x.truncatingRemainder(dividingBy: y))
            }
        }
    }
}
