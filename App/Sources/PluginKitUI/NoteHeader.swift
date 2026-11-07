import Observation
import SwiftUI

/// A band a plugin puts above the text of some notes, such as the week and the day's tasks above a daily note, or
/// a collection's fields under an entry's title. The editor draws every header that applies, by `order`; the note
/// stays plain Markdown.
public struct NoteHeader: Identifiable, Sendable {
    public enum Placement: Sendable {
        /// Above the page, which then shows no title of its own (the band carries it), and does not scroll.
        case aboveNote
        /// Under the page's title, scrolling with the text, as Craft shows a collection entry's fields.
        case underTitle
    }

    /// Dotted and owned by the plugin, such as `daily.header`.
    public let id: String
    /// Top to bottom: lower first.
    public let order: Int
    public let placement: Placement
    /// True when the notes it applies to may not exist yet, such as the daily note of a day nobody wrote in: the
    /// editor then opens a missing file as a blank note and only creates it once text is typed.
    public let createsOnEdit: Bool
    public let appliesTo: @MainActor (Resource) -> Bool
    public let makeView: @MainActor (ViewContext) -> AnyView

    public init(
        id: String,
        order: Int = 0,
        placement: Placement = .aboveNote,
        createsOnEdit: Bool = false,
        appliesTo: @escaping @MainActor (Resource) -> Bool,
        makeView: @escaping @MainActor (ViewContext) -> AnyView
    ) {
        self.id = id
        self.order = order
        self.placement = placement
        self.createsOnEdit = createsOnEdit
        self.appliesTo = appliesTo
        self.makeView = makeView
    }
}

/// Where note headers are registered. Plugins use `context.addNoteHeader`, which also unregisters on unload.
@MainActor
public protocol NoteHeaderRegistry: AnyObject {
    func register(_ header: NoteHeader) -> @MainActor () -> Void
    /// The headers that apply to `resource`, by `order`, then by id.
    func headers(for resource: Resource) -> [NoteHeader]
}

/// The standard `NoteHeaderRegistry`. Observable, so open notes show a header as soon as its plugin loads.
@MainActor
@Observable
public final class NoteHeaderStore: NoteHeaderRegistry {
    private var entries = RegistryEntries<NoteHeader>()

    public init() {}

    public func register(_ header: NoteHeader) -> @MainActor () -> Void {
        let token = entries.insert(header, id: header.id)
        return { [weak self] in self?.entries.remove(token) }
    }

    public func headers(for resource: Resource) -> [NoteHeader] {
        entries.values
            .filter { $0.appliesTo(resource) }
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
    }
}

public extension ServiceKey where Service == any NoteHeaderRegistry {
    static var noteHeaders: ServiceKey<any NoteHeaderRegistry> { ServiceKey<any NoteHeaderRegistry>("ui.note-headers") }
}

@MainActor
public extension PluginContext {
    /// Adds a band above the text of the notes `header.appliesTo` accepts. Throws
    /// `UIContractError.registryMissing("ui.note-headers")` without the shell.
    func addNoteHeader(_ header: NoteHeader) throws {
        guard let registry = service(.noteHeaders) else {
            throw UIContractError.registryMissing(ServiceKey<any NoteHeaderRegistry>.noteHeaders.id)
        }
        let remove = registry.register(header)
        effect { MainActor.assumeIsolated { remove() } }
    }
}
