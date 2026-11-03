import Foundation
import PluginKit
import Yams

/// The YAML of a collection, kept as Yams' node tree so an edit changes only what it touches: other keys, their
/// order and their style come back as they were (comments and indentation do not). Never written without an edit.
struct BaseFile {
    private(set) var root: Node.Mapping

    init(yaml: String) throws {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            root = Node.Mapping([])
            return
        }
        let node: Node?
        do {
            node = try Yams.compose(yaml: yaml)
        } catch {
            throw CollectionError.invalidYAML(String(describing: error))
        }
        guard let mapping = node?.mapping else { throw CollectionError.invalidYAML("the top level is not a map") }
        root = mapping
    }

    func yaml() throws -> String {
        try Yams.serialize(node: .mapping(root), indent: 2, width: -1, allowUnicode: true)
    }

    // MARK: Reading

    var filters: FilterTree? { root["filters"].flatMap(Self.tree) }

    /// The title a ` ```base ` block shows (`name:`, a Loam key); nil when it has none.
    var name: String? { root["name"]?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }

    var properties: [CollectionProperty] {
        guard let mapping = root["properties"]?.mapping else { return [] }
        return mapping.compactMap { key, value in
            guard let name = key.string else { return nil }
            let settings = value.mapping
            return CollectionProperty(
                ref: PropertyRef(name),
                displayName: settings?["displayName"]?.string,
                kind: settings?["type"]?.string.flatMap { PropertyKind(rawValue: $0.lowercased()) },
                options: settings?["options"]?.sequence?.compactMap(\.string) ?? []
            )
        }
    }

    var views: [CollectionViewConfig] {
        (root["views"]?.sequence ?? []).compactMap { node in
            guard let view = node.mapping else { return nil }
            let type = view["type"]?.string ?? "table"
            var options: [String: PropertyValue] = [:]
            for (key, value) in view {
                guard let key = key.string, !Self.viewKeys.contains(key) else { continue }
                options[key] = Self.value(value)
            }
            return CollectionViewConfig(
                type: type,
                name: view["name"]?.string ?? type.capitalized,
                order: view["order"]?.sequence?.compactMap { $0.string.map(PropertyRef.init) } ?? [],
                sort: view["sort"]?.sequence?.compactMap(Self.sort) ?? [],
                groupBy: view["groupBy"].flatMap(Self.sort),
                limit: view["limit"]?.int,
                options: options
            )
        }
    }

    func viewFilters(_ name: String) -> FilterTree? {
        viewNode(name)?["filters"].flatMap(Self.tree)
    }

    private static let viewKeys: Set<String> = ["type", "name", "order", "sort", "groupBy", "limit", "filters"]

    private func viewNode(_ name: String) -> Node.Mapping? {
        root["views"]?.sequence?.first { $0.mapping?["name"]?.string == name }?.mapping
    }

    static func tree(_ node: Node) -> FilterTree? {
        if let text = node.string, node.scalar != nil { return .expression(text) }
        guard let mapping = node.mapping, let (key, value) = mapping.first.map({ ($0.key.string ?? "", $0.value) })
        else { return nil }
        let items = (value.sequence.map(Array.init) ?? [value]).compactMap(tree)
        switch key {
        case "and": return .and(items)
        case "or": return .or(items)
        case "not": return .not(items)
        default: return nil
        }
    }

    private static func sort(_ node: Node) -> CollectionSort? {
        if let text = node.string, node.scalar != nil { return CollectionSort(property: PropertyRef(text)) }
        guard let mapping = node.mapping, let property = mapping["property"]?.string else { return nil }
        return CollectionSort(
            property: PropertyRef(property),
            descending: mapping["direction"]?.string?.uppercased() == "DESC"
        )
    }

    /// A node as a property value: YAML's own types for scalars.
    static func value(_ node: Node) -> PropertyValue {
        switch node {
        case .scalar(let scalar):
            if scalar.style == .plain || scalar.style == .any {
                if node.null != nil { return .null }
                if let flag = node.bool { return .bool(flag) }
                if let number = node.int { return .number(Double(number)) }
                if let number = node.float { return .number(number) }
            }
            return .string(scalar.string)
        case .sequence(let sequence):
            return .list(sequence.map(value))
        case .mapping(let mapping):
            var map: [String: PropertyValue] = [:]
            for (key, element) in mapping { map[key.string ?? ""] = value(element) }
            return .map(map)
        case .alias:
            return .null
        }
    }

    static func node(_ value: PropertyValue) -> Node {
        switch value {
        case .null: return Node("null", Tag(.null))
        case .bool(let flag): return Node(flag ? "true" : "false", Tag(.bool))
        case .number(let number):
            if number == number.rounded(), abs(number) < 1e15 { return Node(String(Int(number)), Tag(.int)) }
            return Node(String(number), Tag(.float))
        case .string(let text): return string(text)
        case .list(let items): return Node(items.map(node), Tag(.seq), .block)
        case .map(let map):
            return Node(map.keys.sorted().map { (string($0), node(map[$0]!)) }, Tag(.map), .block)
        }
    }

    /// A string node: plain where it reads back as the same string, quoted otherwise (Yams decides).
    static func string(_ text: String) -> Node {
        Node(text, Tag(.str))
    }

    // MARK: Editing

    mutating func apply(_ edit: CollectionEdit) throws {
        switch edit {
        case .addView(let type, let name):
            var views = root["views"]?.sequence ?? Node.Sequence([], Tag(.seq), .block)
            let names = Set(views.compactMap { $0.mapping?["name"]?.string })
            var unique = name
            var number = 2
            while names.contains(unique) {
                unique = "\(name) \(number)"
                number += 1
            }
            views.append(Node([(Self.string("type"), Self.string(type)), (Self.string("name"), Self.string(unique))],
                              Tag(.map), .block))
            root["views"] = .sequence(views)
        case .removeView(let name):
            try editViews { views in
                guard let index = views.firstIndex(where: { $0.mapping?["name"]?.string == name }) else {
                    throw CollectionError.unknownView(name)
                }
                views.remove(at: index)
            }
        case .renameView(let name, let to):
            try editView(name) { $0["name"] = Self.string(to) }
        case .moveView(let name, let to):
            try editViews { views in
                guard let index = views.firstIndex(where: { $0.mapping?["name"]?.string == name }) else {
                    throw CollectionError.unknownView(name)
                }
                let view = views.remove(at: index)
                views.insert(view, at: max(0, min(to, views.count)))
            }
        case .setOrder(let name, let order):
            try editView(name) {
                $0["order"] = Node(order.map { Self.string($0.description) }, Tag(.seq), .block)
            }
        case .setSort(let name, let sort):
            try editView(name) { view in
                view["sort"] = sort.isEmpty ? nil : Node(sort.map(Self.sortNode), Tag(.seq), .block)
            }
        case .setGroupBy(let name, let groupBy):
            try editView(name) { $0["groupBy"] = groupBy.map(Self.sortNode) }
        case .setLimit(let name, let limit):
            try editView(name) { $0["limit"] = limit.map { Self.node(.number(Double($0))) } }
        case .setViewOption(let name, let key, let value):
            guard !Self.viewKeys.contains(key) else { throw CollectionError.invalidArgument(key) }
            try editView(name) { $0[key] = value.map(Self.node) }
        case .setProperty(let property):
            var properties = root["properties"]?.mapping ?? Node.Mapping([], Tag(.map), .block)
            let key = property.ref.description
            var settings = properties[key]?.mapping ?? Node.Mapping([], Tag(.map), .block)
            settings["displayName"] = property.displayName.map(Self.string)
            settings["type"] = property.kind.map { Self.string($0.rawValue) }
            settings["options"] = property.options.isEmpty
                ? nil : Node(property.options.map(Self.string), Tag(.seq), .block)
            properties[key] = settings.isEmpty ? nil : .mapping(settings)
            root["properties"] = properties.isEmpty ? nil : .mapping(properties)
        case .removeProperty(let ref):
            let key = ref.description
            if var properties = root["properties"]?.mapping {
                properties[key] = nil
                root["properties"] = properties.isEmpty ? nil : .mapping(properties)
            }
            // A field that is gone leaves every view: its column, its place in the sort, the board's grouping.
            if root["views"]?.sequence != nil { try editViews { views in
                for index in views.indices {
                    guard var view = views[index].mapping else { continue }
                    if let order = view["order"]?.sequence {
                        let kept = Array(order.filter { $0.string != key })
                        view["order"] = kept.isEmpty ? nil : .sequence(Node.Sequence(kept, order.tag, order.style))
                    }
                    if let sort = view["sort"]?.sequence {
                        let kept = Array(sort.filter { $0.mapping?["property"]?.string != key })
                        view["sort"] = kept.isEmpty ? nil : .sequence(Node.Sequence(kept, sort.tag, sort.style))
                    }
                    if view["groupBy"]?.mapping?["property"]?.string == key { view["groupBy"] = nil }
                    views[index] = .mapping(view)
                }
            } }
        case .addFilter(let view, let expression):
            try editFilters(view) { filters in
                let added = Self.string(expression)
                guard let filters else { return Node([(Self.string("and"), Node([added], Tag(.seq), .block))]) }
                if var mapping = filters.mapping, var items = mapping["and"]?.sequence {
                    items.append(added)
                    mapping["and"] = .sequence(items)
                    return .mapping(mapping)
                }
                return Node([(Self.string("and"), Node([filters, added], Tag(.seq), .block))])
            }
        case .removeFilter(let view, let expression):
            try editFilters(view) { filters in
                guard let filters else { return nil }
                if filters.string == expression, filters.scalar != nil { return nil }
                guard var mapping = filters.mapping, var items = mapping["and"]?.sequence else { return filters }
                items = Node.Sequence(items.filter { $0.string != expression }, items.tag, items.style)
                if items.isEmpty { return nil }
                mapping["and"] = .sequence(items)
                return .mapping(mapping)
            }
        }
    }

    private static func sortNode(_ sort: CollectionSort) -> Node {
        Node([
            (string("property"), string(sort.property.description)),
            (string("direction"), string(sort.descending ? "DESC" : "ASC")),
        ], Tag(.map), .block)
    }

    private mutating func editViews(_ change: (inout Node.Sequence) throws -> Void) throws {
        var views = root["views"]?.sequence ?? Node.Sequence([], Tag(.seq), .block)
        try change(&views)
        root["views"] = .sequence(views)
    }

    private mutating func editView(_ name: String, _ change: (inout Node.Mapping) throws -> Void) throws {
        try editViews { views in
            guard let index = views.firstIndex(where: { $0.mapping?["name"]?.string == name }),
                  var view = views[index].mapping else { throw CollectionError.unknownView(name) }
            try change(&view)
            views[index] = .mapping(view)
        }
    }

    private mutating func editFilters(_ view: String?, _ change: (Node?) throws -> Node?) throws {
        if let view {
            try editView(view) { $0["filters"] = try change($0["filters"]) }
        } else {
            root["filters"] = try change(root["filters"])
        }
    }
}
