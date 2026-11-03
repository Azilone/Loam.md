import Foundation
import Observation

/// The standard `PanelRegistry`. Observable, so the sidebars and status bar refresh when a plugin loads or
/// unloads. The shell provides it as `ui.panels`; tests use it as the real thing.
@MainActor
@Observable
public final class PanelRegistryStore: PanelRegistry {
    private var entries = RegistryEntries<Panel>()
    private var linkEntries = RegistryEntries<SidebarLink>()
    private var itemEntries = RegistryEntries<NewItem>()
    private var sectionEntries = RegistryEntries<SidebarSection>()

    public init() {}

    /// Every registered panel, by id.
    public var all: [Panel] { entries.values.sorted { $0.id < $1.id } }

    public func register(_ panel: Panel) -> @MainActor () -> Void {
        let token = entries.insert(panel, id: panel.id)
        return { [weak self] in self?.entries.remove(token) }
    }

    public func panels(in slot: Slot) -> [Panel] {
        entries.values
            .filter { $0.slot == slot }
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
    }

    public func register(_ link: SidebarLink) -> @MainActor () -> Void {
        let token = linkEntries.insert(link, id: link.id)
        return { [weak self] in self?.linkEntries.remove(token) }
    }

    public var links: [SidebarLink] {
        linkEntries.values.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
    }

    public func register(_ item: NewItem) -> @MainActor () -> Void {
        let token = itemEntries.insert(item, id: item.id)
        return { [weak self] in self?.itemEntries.remove(token) }
    }

    public var newItems: [NewItem] {
        itemEntries.values.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
    }

    public func register(_ section: SidebarSection) -> @MainActor () -> Void {
        let token = sectionEntries.insert(section, id: section.id)
        return { [weak self] in self?.sectionEntries.remove(token) }
    }

    public var sections: [SidebarSection] {
        sectionEntries.values.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
    }
}
