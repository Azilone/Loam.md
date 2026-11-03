import Observation
import SwiftUI

/// A view a plugin floats over the workspace window, in one of its corners, such as the Assistant's bubble at the
/// bottom right. It stays inside the window (unlike an `NSPanel`, which floats above every app), above the pages and
/// sidebars and below the palette and toasts. The view sizes itself; the shell only places it.
public struct WindowOverlay: Identifiable, Sendable {
    public enum Corner: Sendable {
        case bottomTrailing
    }

    /// Dotted and owned by the plugin, such as `assistant.bubble`.
    public let id: String
    public let corner: Corner
    /// Several overlays in one corner are drawn by `order`, the highest on top.
    public let order: Int
    public let makeView: @MainActor () -> AnyView

    public init(id: String, corner: Corner = .bottomTrailing, order: Int = 0, makeView: @escaping @MainActor () -> AnyView) {
        self.id = id
        self.corner = corner
        self.order = order
        self.makeView = makeView
    }
}

/// Where window overlays are registered. Plugins use `context.addWindowOverlay`, which also unregisters on unload.
@MainActor
public protocol WindowOverlayRegistry: AnyObject {
    func register(_ overlay: WindowOverlay) -> @MainActor () -> Void
    /// The overlays of `corner`, by `order`, then by id.
    func overlays(in corner: WindowOverlay.Corner) -> [WindowOverlay]
}

/// The standard `WindowOverlayRegistry`. Observable, so the window shows an overlay as soon as its plugin loads.
@MainActor
@Observable
public final class WindowOverlayStore: WindowOverlayRegistry {
    private var entries = RegistryEntries<WindowOverlay>()

    public init() {}

    public func register(_ overlay: WindowOverlay) -> @MainActor () -> Void {
        let token = entries.insert(overlay, id: overlay.id)
        return { [weak self] in self?.entries.remove(token) }
    }

    public func overlays(in corner: WindowOverlay.Corner) -> [WindowOverlay] {
        entries.values
            .filter { $0.corner == corner }
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
    }
}

public extension ServiceKey where Service == any WindowOverlayRegistry {
    static var windowOverlays: ServiceKey<any WindowOverlayRegistry> {
        ServiceKey<any WindowOverlayRegistry>("ui.window-overlays")
    }
}

@MainActor
public extension PluginContext {
    /// Floats `overlay` over the workspace window. Throws `UIContractError.registryMissing("ui.window-overlays")`
    /// without the shell.
    func addWindowOverlay(_ overlay: WindowOverlay) throws {
        guard let registry = service(.windowOverlays) else {
            throw UIContractError.registryMissing(ServiceKey<any WindowOverlayRegistry>.windowOverlays.id)
        }
        let remove = registry.register(overlay)
        effect { MainActor.assumeIsolated { remove() } }
    }
}
