import Foundation
import PluginKit
import Yams

/// Frontmatter properties, parsed from the YAML that `MarkdownFrontmatter.split` extracts.
enum Frontmatter {
    /// Frontmatter properties. Invalid YAML yields no properties instead of an error.
    static func properties(from yaml: String) -> [String: PropertyValue] {
        guard let loaded = try? Yams.load(yaml: yaml), case .map(let map) = convert(loaded) else { return [:] }
        return map
    }

    private static func convert(_ value: Any?) -> PropertyValue {
        switch value {
        case nil, is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .number(Double(value))
        case let value as Double:
            return .number(value)
        case let value as String:
            return .string(value)
        case let value as Date:
            return .string(dateString(value))
        case let value as [Any]:
            return .list(value.map { convert($0) })
        case let value as [AnyHashable: Any]:
            var map: [String: PropertyValue] = [:]
            for (key, element) in value { map[String(describing: key.base)] = convert(element) }
            return .map(map)
        default:
            return .string(String(describing: value!))
        }
    }

    private static func dateString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        if parts.hour == 0, parts.minute == 0, parts.second == 0 {
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
