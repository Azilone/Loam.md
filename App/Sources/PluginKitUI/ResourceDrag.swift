import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// What is dragged inside the workspace: a resource (a note from a sidebar list) or an open tab, by its id.
///
/// It travels as a short string, `so-resource:<kind>/<path>` or `loam-tab:<uuid>`, so it is easy to read in tests
/// and logs. The tab id is a bare `UUID` because the workspace model (which owns `TabID`) builds on this module.
public enum DragPayload: Hashable, Sendable {
    case resource(Resource)
    case tab(UUID)

    private static let resourcePrefix = "loam-resource:"
    private static let tabPrefix = "loam-tab:"

    public var string: String {
        switch self {
        case .resource(let resource): Self.resourcePrefix + resource.kind.rawValue + "/" + resource.path
        case .tab(let id): Self.tabPrefix + id.uuidString
        }
    }

    /// Nil for anything that is not one of the two forms above, so a stray drop is ignored.
    public init?(string: String) {
        if string.hasPrefix(Self.tabPrefix) {
            guard let id = UUID(uuidString: String(string.dropFirst(Self.tabPrefix.count))) else { return nil }
            self = .tab(id)
            return
        }
        guard string.hasPrefix(Self.resourcePrefix) else { return nil }
        let rest = string.dropFirst(Self.resourcePrefix.count)
        guard let slash = rest.firstIndex(of: "/"), let kind = Resource.Kind(rawValue: String(rest[..<slash])) else {
            return nil
        }
        let path = String(rest[rest.index(after: slash)...])
        guard !path.isEmpty else { return nil }
        self = .resource(Resource(kind: kind, path: path))
    }

    // MARK: Pasteboard

    /// The drag type: a private type no other view accepts.
    ///
    /// Not plain text, because the editor's `NSTextView` (an AppKit view inside the pane) accepts plain text drops
    /// and AppKit hands a drop to the deepest view that takes its type: dropping a tab on an editor pane would type
    /// `loam-tab:…` into the note instead of reaching the pane's drop target. Not an exported custom `UTType` either,
    /// which needs an Info.plist entry that `swift run` and tests do not have. A type made from a MIME tag is
    /// dynamic (`dyn.…`): the same identifier on every run, with no declaration.
    public static let type: UTType = UTType(
        tag: "application/x-loam-drag",
        tagClass: .mimeType,
        conformingTo: .data
    ) ?? .data

    /// An item provider carrying the payload's string as UTF-8 under `type`, for `onDrag`.
    public func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(string.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        provider.suggestedName = suggestedName
        return provider
    }

    private var suggestedName: String? {
        if case .resource(let resource) = self { return resource.name }
        return nil
    }

    /// Reads a payload from a provider made by `itemProvider()`; nil for anything else. Calls back on the main
    /// actor.
    public static func load(from provider: NSItemProvider, _ completion: @escaping @MainActor @Sendable (DragPayload?) -> Void) {
        guard provider.hasItemConformingToTypeIdentifier(type.identifier) else {
            Task { @MainActor in completion(nil) }
            return
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            let payload = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap { DragPayload(string: $0) }
            Task { @MainActor in completion(payload) }
        }
    }
}

extension View {
    /// Lets the user drag `resource` into the workspace: onto a pane's edge to open it beside, onto its center or
    /// a tab bar to open it as a tab.
    ///
    /// Uses `onDrag` with an `NSItemProvider` rather than `draggable`, so the payload has the private `DragPayload`
    /// type (see `DragPayload.type`) without a `Transferable` type declared in an Info.plist.
    ///
    /// What follows the pointer is drawn by `DragGhost`: a row over the sidebar, a card over the pages, a larger
    /// card over a split zone. `symbol` is the resource's icon, shown in the row.
    public func draggableResource(_ resource: Resource, row symbol: String = "doc.text") -> some View {
        onDrag {
            DragSession.shared.begin(.resource(resource), symbol: symbol)
            return DragPayload.resource(resource).itemProvider()
        } preview: {
            HiddenDragPreview()
        }
    }
}
