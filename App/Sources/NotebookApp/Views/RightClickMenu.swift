import AppKit
import SwiftUI

/// One item of a `RightClickMenu`; a nil title is a separator.
struct RightClickItem {
    var title: String?
    var symbol: String?
    var perform: @MainActor () -> Void = {}

    static let separator = RightClickItem(title: nil)
}

extension View {
    /// A menu on a right-click (or a Control-click) anywhere in the view's frame, built when it opens.
    ///
    /// SwiftUI's `.contextMenu` never sees a right-click that an AppKit view under it takes (the editor's text view
    /// scrolls under the page toolbar) or that the window's title bar takes (the tabs live in it), so this watches
    /// the window's right-clicks with a local event monitor, as `PaneClickDetector` watches its clicks, and keeps
    /// the ones that land on it. Empty items open nothing and let the click through.
    func rightClickMenu(_ items: @escaping @MainActor () -> [RightClickItem]) -> some View {
        background(RightClickMenu(items: items))
    }
}

private struct RightClickMenu: NSViewRepresentable {
    let items: @MainActor () -> [RightClickItem]

    func makeNSView(context: Context) -> MenuView {
        let view = MenuView()
        view.items = items
        return view
    }

    func updateNSView(_ view: MenuView, context: Context) {
        view.items = items
    }

    final class MenuView: NSView {
        var items: (@MainActor () -> [RightClickItem])?
        private var monitor: Any?
        /// The open menu's actions, by item tag.
        private var actions: [@MainActor () -> Void] = []

        /// Never the target of a click: it only watches.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
            }
        }

        /// True when the click opened the menu, so no other view gets it.
        private func handle(_ event: NSEvent) -> Bool {
            let isRightClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard isRightClick, let window, event.window === window, !isHiddenOrHasHiddenAncestor,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
            let items = items?() ?? []
            guard items.contains(where: { $0.title != nil }) else { return false }
            let menu = NSMenu()
            actions = []
            for item in items {
                guard let title = item.title else {
                    if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                    continue
                }
                let menuItem = NSMenuItem(title: String(localized: String.LocalizationValue(title)), action: #selector(choose(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.tag = actions.count
                menuItem.image = item.symbol.flatMap { NSImage.symbol($0, accessibilityDescription: nil) }
                actions.append(item.perform)
                menu.addItem(menuItem)
            }
            if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return true
        }

        @objc private func choose(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            // After the menu has closed, so a sheet the action opens finds the window free.
            let action = actions[sender.tag]
            DispatchQueue.main.async { action() }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        isolated deinit {
            removeMonitor()
        }
    }
}
