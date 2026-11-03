import Foundation

/// The comparison rules `PropertyFilter` and `SortKey` document, shared by every plugin that filters or sorts
/// property values (`note-query`, collections).
public enum PropertyComparison {
    /// Equality: strings ignore case, numbers and booleans also match their string spelling, lists and maps
    /// compare element by element.
    public static func equals(_ a: PropertyValue, _ b: PropertyValue) -> Bool {
        switch (a, b) {
        case (.list(let x), .list(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { equals($0, $1) }
        case (.map(let x), .map(let y)):
            return x.count == y.count && x.allSatisfy { key, value in y[key].map { equals(value, $0) } ?? false }
        case (.null, .null):
            return true
        default:
            return order(a, b) == .orderedSame
        }
    }

    /// Order of two scalar values, or nil when they cannot be compared (different kinds, lists, maps, null).
    public static func order(_ a: PropertyValue, _ b: PropertyValue) -> ComparisonResult? {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return compare(x, y)
        case (.number(let x), .string(let y)):
            return Double(y.trimmingCharacters(in: .whitespaces)).map { compare(x, $0) }
        case (.string(let x), .number(let y)):
            return Double(x.trimmingCharacters(in: .whitespaces)).map { compare($0, y) }
        case (.string(let x), .string(let y)):
            return compare(x.lowercased(), y.lowercased())
        case (.bool(let x), .bool(let y)):
            return compare(x ? 1 : 0, y ? 1 : 0)
        case (.bool(let x), .string(let y)):
            return bool(y).map { compare(x ? 1 : 0, $0 ? 1 : 0) }
        case (.string(let x), .bool(let y)):
            return bool(x).map { compare($0 ? 1 : 0, y ? 1 : 0) }
        default:
            return nil
        }
    }

    /// Total order for sorting present values: by kind (bool, number, string, list, map), then by `order`.
    public static func sortOrder(_ a: PropertyValue, _ b: PropertyValue) -> ComparisonResult {
        let (rankA, rankB) = (rank(a), rank(b))
        if rankA != rankB { return rankA < rankB ? .orderedAscending : .orderedDescending }
        switch (a, b) {
        case (.list(let x), .list(let y)):
            for (left, right) in zip(x, y) {
                let result = sortOrder(left, right)
                if result != .orderedSame { return result }
            }
            return compare(Double(x.count), Double(y.count))
        case (.map(let x), .map(let y)):
            return compare(Double(x.count), Double(y.count))
        default:
            return order(a, b) ?? .orderedSame
        }
    }

    /// Whether a filter matches a note's value for its key (nil when the note lacks the property).
    public static func matches(_ filter: PropertyFilter, _ actual: PropertyValue?) -> Bool {
        let present: PropertyValue? = actual == .null ? nil : actual
        switch filter.op {
        case .exists:
            return present != nil
        case .missing:
            return present == nil
        case .equals:
            guard let present, let wanted = filter.value else { return false }
            return equals(present, wanted)
        case .notEquals:
            guard let present, let wanted = filter.value else { return true }
            return !equals(present, wanted)
        case .contains:
            guard let present, let wanted = filter.value else { return false }
            switch present {
            case .list(let elements):
                return elements.contains { equals($0, wanted) }
            case .string(let haystack):
                guard let needle = text(of: wanted) else { return false }
                return haystack.lowercased().contains(needle.lowercased())
            default:
                return false
            }
        case .lessThan:
            guard let present, let wanted = filter.value else { return false }
            return order(present, wanted) == .orderedAscending
        case .greaterThan:
            guard let present, let wanted = filter.value else { return false }
            return order(present, wanted) == .orderedDescending
        }
    }

    /// The text of a scalar value (`3`, `2.5`, `true`, a string), nil for lists, maps and null.
    public static func text(of value: PropertyValue) -> String? {
        switch value {
        case .string(let text): return text
        case .number(let number): return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .bool(let flag): return flag ? "true" : "false"
        default: return nil
        }
    }

    private static func rank(_ value: PropertyValue) -> Int {
        switch value {
        case .null: return 5
        case .bool: return 0
        case .number: return 1
        case .string: return 2
        case .list: return 3
        case .map: return 4
        }
    }

    /// A property by exact key, else by key ignoring case.
    public static func property(_ key: String, of properties: [String: PropertyValue]) -> PropertyValue? {
        if let value = properties[key] { return value }
        return properties.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    private static func bool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
