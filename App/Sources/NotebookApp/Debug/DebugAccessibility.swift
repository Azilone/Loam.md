#if DEBUG || LOAM_AGENT_BRIDGE
import AppKit
import DebugProtocol

/// The accessibility tree of a window as JSON, and the lookup of an element by identifier or label. Frames are in
/// points from the window content's top-left corner, the coordinates every pointer command uses.
@MainActor
struct DebugAccessibility {
    let window: NSWindow

    /// One element: what the tree shows of it.
    struct Element {
        let object: AnyObject
        let role: String
        let identifier: String
        let label: String
        let value: String
        let frame: CGRect

        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    }

    /// SwiftUI builds its accessibility elements (buttons, rows, labels) only while an accessibility client is
    /// connected. Telling the app one is (the attribute assistive technologies and UI automation set) makes them
    /// exist without any permission or the real accessibility service.
    static func enableTree() {
        NSApp.setAccessibilityEnabled(true)
        let set = Selector(("accessibilitySetValue:forAttribute:"))
        guard NSApp.responds(to: set) else { return }
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            _ = NSApp.perform(set, with: NSNumber(value: true), with: attribute)
        }
    }

    private var contentHeight: CGFloat { window.contentView?.frame.height ?? window.frame.height }
    private static let nodeLimit = 6000

    /// The tree below the window's content, `depth` levels deep.
    func tree(depth: Int) -> DebugValue {
        guard let root = window.contentView else { return .null }
        var budget = Self.nodeLimit
        return json(of: root, depth: depth, budget: &budget)
    }

    /// Every element whose identifier, label, role or value contains `text` (ignoring case), in tree order.
    func find(_ text: String) -> [Element] {
        let needle = text.lowercased()
        return elements().filter {
            [$0.identifier, $0.label, $0.role, $0.value].contains { $0.lowercased().contains(needle) }
        }
    }

    /// The element with this identifier (exact, else partial), or this label (ignoring case: exact, else partial).
    func element(id: String? = nil, label: String? = nil) -> Element? {
        let all = elements().filter { $0.frame.width > 0 && $0.frame.height > 0 }
        if let id {
            return all.first { $0.identifier == id } ?? all.first { $0.identifier.localizedCaseInsensitiveContains(id) }
        }
        if let label {
            return all.first { $0.label.caseInsensitiveCompare(label) == .orderedSame || $0.value.caseInsensitiveCompare(label) == .orderedSame }
                ?? all.first { $0.label.localizedCaseInsensitiveContains(label) }
        }
        return nil
    }

    /// Everything with a role, flattened.
    func elements() -> [Element] {
        guard let root = window.contentView else { return [] }
        var out: [Element] = []
        var budget = Self.nodeLimit
        walk(root, depth: 40, budget: &budget) { out.append($0) }
        return out
    }

    func json(of element: Element) -> DebugValue {
        var object: [String: DebugValue] = ["role": .string(element.role), "frame": Self.rect(element.frame)]
        if !element.identifier.isEmpty { object["id"] = .string(element.identifier) }
        if !element.label.isEmpty { object["label"] = .string(element.label) }
        if !element.value.isEmpty { object["value"] = .string(element.value) }
        object["class"] = .string(String(describing: type(of: element.object)))
        return .object(object)
    }

    static func rect(_ frame: CGRect) -> DebugValue {
        [
            "x": .number(frame.minX.rounded()), "y": .number(frame.minY.rounded()),
            "w": .number(frame.width.rounded()), "h": .number(frame.height.rounded()),
        ]
    }

    // MARK: Walking

    /// SwiftUI's accessibility nodes implement the accessibility methods without adopting `NSAccessibilityProtocol`
    /// formally, so they are read through their selectors (a missing one reads as nil, never an exception).
    private func read(_ object: AnyObject, _ name: String) -> Any? {
        guard let object = object as? NSObject, object.responds(to: Selector(name)) else { return nil }
        return object.value(forKey: name)
    }

    func element(for object: AnyObject) -> Element {
        func text(_ value: Any?) -> String {
            switch value {
            case let string as String: string
            case let number as NSNumber: number.stringValue
            case nil: ""
            default: String(describing: value!)
            }
        }
        let role = (read(object, "accessibilityRole") as? String) ?? ""
        let frame = (read(object, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
        return Element(
            object: object,
            role: role,
            identifier: text(read(object, "accessibilityIdentifier")),
            label: text(read(object, "accessibilityLabel")),
            value: text(read(object, "accessibilityValue")),
            frame: windowRect(frame)
        )
    }

    /// A screen rectangle (from the bottom left) as a window rectangle from the content's top left.
    private func windowRect(_ screen: CGRect) -> CGRect {
        guard screen != .zero else { return .zero }
        let inWindow = window.convertFromScreen(screen)
        return CGRect(x: inWindow.minX, y: contentHeight - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    private func children(of object: AnyObject) -> [AnyObject] {
        let declared = ((read(object, "accessibilityChildren") as? [Any]) ?? []).compactMap { $0 as AnyObject }
        if !declared.isEmpty { return declared }
        if let view = object as? NSView { return view.subviews.filter { !$0.isHidden } }
        return []
    }

    private func walk(_ object: AnyObject, depth: Int, budget: inout Int, visit: (Element) -> Void) {
        guard budget > 0 else { return }
        budget -= 1
        let current = element(for: object)
        if !current.role.isEmpty { visit(current) }
        guard depth > 0 else { return }
        for child in children(of: object) { walk(child, depth: depth - 1, budget: &budget, visit: visit) }
    }

    private func json(of object: AnyObject, depth: Int, budget: inout Int) -> DebugValue {
        budget -= 1
        var node = json(of: element(for: object)).object ?? [:]
        if depth > 0, budget > 0 {
            let kids = children(of: object).prefix(max(0, budget)).map { json(of: $0, depth: depth - 1, budget: &budget) }
            if !kids.isEmpty { node["children"] = .array(Array(kids)) }
        }
        return .object(node)
    }
}
#endif
