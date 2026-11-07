import AppKit
import Foundation
import Observation
import PluginKitUI
import WorkspaceModel

/// The shell's `Workspace` (`ui.workspace`): the observable owner of the `WorkspaceLayout` value the window renders.
///
/// Every change goes through `update`, which keeps the per-tab `ViewContext`s in step, reports a new active resource
/// and asks for the layout to be saved. The rules themselves (placement, close, splits) stay in the pure model.
@MainActor
@Observable
public final class WorkspaceController: Workspace {
    public private(set) var layout: WorkspaceLayout
    public private(set) var chrome: WorkspaceChrome

    /// Called after every change worth saving. Set by the session.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Called when the focused tab's resource changes; the session sends `ActiveResourceChanged` from it.
    @ObservationIgnored public var onActiveResourceChange: ((Resource?) -> Void)?

    /// Each pane's page frame in the window, measured by its hosting view (`PaneHostView`); read when a drag starts,
    /// to picture the page, and when a page grows from a card.
    @ObservationIgnored var paneFrames: [PaneID: CGRect] = [:]

    /// One context per tab, kept for the tab's life so a view rebuilt by SwiftUI finds its state again.
    @ObservationIgnored private var contexts: [TabID: ViewContext] = [:]
    @ObservationIgnored private var lastActive: Resource?

    public init(snapshot: WorkspaceSnapshot = WorkspaceSnapshot()) {
        layout = snapshot.layout
        chrome = snapshot.chrome
        lastActive = snapshot.layout.activeTab?.resource
    }

    public var snapshot: WorkspaceSnapshot { WorkspaceSnapshot(layout: layout, chrome: chrome) }

    // MARK: Workspace

    public func open(_ resource: Resource, placement: Placement, from origin: OpenOrigin?) {
        let before = layout.activeTab
        change = Change(origin: origin, isBack: false)
        defer { change = nil }
        update { $0.open(resource, placement: placement) }
        // A tab that now shows something else remembers what it showed, for "Back" (Craft's page toolbar), and
        // where the new page came from, so Back can shrink it to there.
        if let before, let after = layout.tab(before.id), after.resource != before.resource {
            history[before.id, default: []].append(before.resource)
            if let origin { backOrigins[before.id, default: [:]][before.resource] = origin }
            // A new page ends the way Forward went, as in a browser.
            forward[before.id] = nil
        }
    }

    /// What a new tab (Cmd+T) shows: the home page. Set by the session; nil means the shell has none, so
    /// `openNewTab` does nothing.
    @ObservationIgnored public var newTabResource: (@MainActor () -> Resource?)?
    /// The notes edited last, the most recent first: the pages build an editor ahead on one of them while the app is
    /// idle (`PageStackView`), so the first note opened is not the first editor built. Set by the session.
    @ObservationIgnored public var recentNotes: (@MainActor () async -> [Resource])?
    /// What the left sidebar's first row opens (All Notes): its page is built ahead too. Set by the session.
    @ObservationIgnored public var firstLink: (@MainActor () -> Resource?)?
    /// New tabs nobody has used yet, with what they show: a second Cmd+T on one opens no tab (it brings Quick Open back) and leaving one
    /// closes it. A tab stops being one as soon as it shows something else.
    /// Not persisted: after a relaunch an untouched new tab is an ordinary home tab. The entry goes as soon as the
    /// tab shows another resource, so coming back to the home page does not make it new again.
    private var newTabs: [TabID: Resource] = [:]
    /// Called after a new tab opens, so the shell can put the keyboard where you can act at once (Quick Open).
    @ObservationIgnored public var onNewTab: (() -> Void)?
    /// Called after the selected tab stops being an untouched new tab (closed or another tab selected), so the shell can
    /// close the Quick Open that new tab brought up.
    @ObservationIgnored public var onNewTabLeft: (() -> Void)?

    private func isUntouchedNewTab(_ id: TabID, in layout: WorkspaceLayout) -> Bool {
        guard let shown = newTabs[id], layout.tab(id)?.resource == shown else { return false }
        return true
    }

    /// True for a tab opened with Cmd+T that still shows what it opened with; the tab bar titles it "New Tab".
    public func isNewTab(_ id: TabID) -> Bool { isUntouchedNewTab(id, in: layout) }

    /// Opens a new tab after the selected one, showing the home page, and selects it. While the
    /// selected tab is itself a new tab nobody has used, opens no other tab but brings Quick Open back.
    public func openNewTab() {
        guard let resource = newTabResource?() else { return }
        if let active = layout.activeTab, isUntouchedNewTab(active.id, in: layout) {
            onNewTab?()
            return
        }
        var id: TabID?
        update { id = $0.openNewTab(resource) }
        if let id {
            newTabs[id] = resource
            onNewTab?()
        }
    }

    /// What each tab showed before, most recent last; for this session only.
    public private(set) var history: [TabID: [Resource]] = [:]
    /// What each tab showed before Back took it away, next one last: Forward shows it again.
    public private(set) var forward: [TabID: [Resource]] = [:]
    /// The resources of the tabs closed in this session, last closed last, for "Reopen Closed Tab".
    public private(set) var closedTabs: [Resource] = []
    /// Where the page that replaced a resource came from, per tab, so Back shrinks the page to there.
    @ObservationIgnored private var backOrigins: [TabID: [Resource: OpenOrigin]] = [:]

    // MARK: Page changes

    /// The user action behind the update in progress, which says how a replaced page arrives.
    private struct Change {
        var origin: OpenOrigin?
        var isBack: Bool
    }
    @ObservationIgnored private var change: Change?
    /// How each pane's page last changed, read by the pane's transition while the old page leaves and the new one
    /// arrives (`PageStackView`). Not observed: it is set in the same update as the layout the views redraw for.
    @ObservationIgnored private var pageChanges: [PaneID: (key: PageKey, change: PageChange)] = [:]
    /// Counts, per tab, the page changes that make a new view even for a view type that follows its resource
    /// (`ViewType.followsResource`): every change but a page replaced in place (`PageChange.replaced`).
    @ObservationIgnored private var pageGenerations: [TabID: Int] = [:]

    /// Part of a page's identity for a view that follows its resource: the same while links and sidebar rows replace
    /// the page, another one once a page comes another way (from a card, Back).
    func pageGeneration(of tab: TabID) -> Int { pageGenerations[tab] ?? 0 }

    /// How the page `key` of `pane` arrived: the change recorded for it, else a cross-fade.
    func pageChange(for pane: PaneID, showing key: PageKey?) -> PageChange {
        guard let key, let recorded = pageChanges[pane], recorded.key == key else { return .crossfade }
        return recorded.change
    }

    /// The pose of the pane's arriving or leaving page, measured against the pane as it is on screen.
    func pageEffect(for pane: PaneID, leaving: Bool) -> PageEffect {
        let frame = paneFrames[pane] ?? .zero
        guard let recorded = pageChanges[pane]?.change else { return .identity }
        return leaving ? recorded.leaving(in: frame) : recorded.arriving(in: frame)
    }

    public func canGoBack(in tab: TabID) -> Bool { contexts[tab]?.hasBack == true || !(history[tab] ?? []).isEmpty }

    /// Closes what the tab's view shows over its page (a diagram shown large), else shows the tab's previous resource
    /// again; selects the tab.
    public func goBack(in tab: TabID) {
        if let back = contexts[tab]?.back {
            back()
            return
        }
        guard let current = layout.tab(tab)?.resource, let previous = history[tab]?.popLast() else { return }
        forward[tab, default: []].append(current)
        change = Change(origin: backOrigins[tab]?.removeValue(forKey: previous), isBack: true)
        defer { change = nil }
        update {
            $0.show(previous, in: tab)
            $0.select(tab)
        }
    }

    public func canGoForward(in tab: TabID) -> Bool { !(forward[tab] ?? []).isEmpty }

    /// Shows again the resource Back took away from the tab, and selects the tab.
    public func goForward(in tab: TabID) {
        guard let current = layout.tab(tab)?.resource, let next = forward[tab]?.popLast() else { return }
        history[tab, default: []].append(current)
        update {
            $0.show(next, in: tab)
            $0.select(tab)
        }
    }

    /// Back and Forward in the active tab, for the menus and their shortcuts.
    public func goBack() { if let tab = layout.activeTab { goBack(in: tab.id) } }
    public func goForward() { if let tab = layout.activeTab { goForward(in: tab.id) } }

    /// Opens the last closed tab again, in a new tab of the focused pane; does nothing when none was closed.
    public func reopenClosedTab() {
        guard let resource = closedTabs.popLast() else { return }
        update { _ = $0.openNewTab(resource) }
    }

    public var activeResource: Resource? { layout.activeTab?.resource }

    // MARK: User actions, forwarded to the model

    public func select(_ tab: TabID) {
        update { $0.select(tab) }
    }
    public func focus(_ pane: PaneID) { update { $0.focus(pane) } }
    public func close(_ tab: TabID) {
        // An untouched new tab shows nothing worth reopening.
        if let closing = layout.tab(tab), !isUntouchedNewTab(tab, in: layout) { closedTabs.append(closing.resource) }
        update { $0.close(tab) }
        history[tab] = nil
        forward[tab] = nil
        backOrigins[tab] = nil
    }

    /// Shows a tab with another view type (the page's view switcher, "Open with"); nil goes back to the default.
    public func setViewType(_ id: String?, for tab: TabID) { update { $0.setViewType(id, for: tab) } }

    public func setFractions(split: UUID, _ fractions: [Double]) {
        update { $0.setFractions(split: split, fractions) }
    }

    /// Follows notes moved inside the vault (`NotesMoved`).
    /// The history is dropped: it may name the old paths.
    public func retarget(_ moves: [String: String]) {
        update { $0.retarget(moves) }
        history = [:]
        forward = [:]
        closedTabs = []
        backOrigins = [:]
    }

    /// Closes the tabs whose resource matches, such as the notes deleted outside the app, and forgets them in the
    /// history, so "Back" never reopens a deleted note.
    public func closeTabs(where shouldClose: (Resource) -> Bool) {
        update { $0.closeAll(where: shouldClose) }
        history = history.mapValues { $0.filter { !shouldClose($0) } }.filter { !$0.value.isEmpty }
        forward = forward.mapValues { $0.filter { !shouldClose($0) } }.filter { !$0.value.isEmpty }
        closedTabs.removeAll(where: shouldClose)
        backOrigins = backOrigins.mapValues { $0.filter { !shouldClose($0.key) } }
    }

    // MARK: Chrome

    public func setSidebar(_ slot: Slot, visible: Bool) {
        var chrome = self.chrome
        switch slot {
        case .leading: chrome.showsLeading = visible
        case .trailing: chrome.showsTrailing = visible
        case .statusBar: return
        }
        if chrome != self.chrome { beginSidebarSlide(slot) }
        updateChrome(chrome)
    }

    /// The sidebar that is showing or hiding, from the moment it starts until its slide has settled; nil otherwise.
    /// The window reads it in the same pass that lays out the new width: the pages are laid out once at their new
    /// width and only their edge follows the column (`SplitTreeView.follow`), the window holds still and the
    /// pages ignore the pointer.
    public private(set) var slidingSidebar: Slot?
    public var isSidebarSliding: Bool { slidingSidebar != nil }
    @ObservationIgnored private var slideGeneration = 0

    private func beginSidebarSlide(_ slot: Slot) {
        slideGeneration += 1
        let generation = slideGeneration
        slidingSidebar = slot
        Motion.isSidebarSliding = !Motion.reduceMotion
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(SidebarMotion.duration + 0.05))
            guard let self, self.slideGeneration == generation else { return }
            self.slidingSidebar = nil
            Motion.isSidebarSliding = false
        }
    }

    public func showInspector() {
        setSidebar(.trailing, visible: true)
    }

    public func toggleSidebar(_ slot: Slot) {
        setSidebar(slot, visible: !(slot == .leading ? chrome.showsLeading : chrome.showsTrailing))
    }

    public func selectPanel(_ id: String, in slot: Slot) {
        var chrome = self.chrome
        switch slot {
        case .leading: chrome.leadingPanel = id
        case .trailing: chrome.trailingPanel = id
        case .statusBar: return
        }
        updateChrome(chrome)
    }

    // MARK: Views

    /// The context of a tab, created on first use. A tab whose resource changed (a move, `.replace`) gets a new
    /// one, since a context names one resource for its whole life.
    public func context(for tab: Tab) -> ViewContext {
        if let existing = contexts[tab.id], existing.resource == tab.resource { return existing }
        // Back to the page kept under this one: the page goes on with the context it had.
        let context: ViewContext
        if let index = keptContexts[tab.id]?.firstIndex(where: { $0.resource == tab.resource }),
           let kept = keptContexts[tab.id]?.remove(at: index) {
            context = kept
            context.isActive = tab.id == layout.activeTab?.id
        } else {
            context = ViewContext(resource: tab.resource, state: tab.state, isActive: tab.id == layout.activeTab?.id)
        }
        let id = tab.id
        context.onStateChange = { [weak self] data in
            MainActor.assumeIsolated { self?.update { $0.setState(data, for: id) } }
        }
        contexts[tab.id] = context
        return context
    }

    /// The contexts of the pages kept under their tab's page, by tab, the most recent last.
    @ObservationIgnored private var keptContexts: [TabID: [ViewContext]] = [:]

    /// How many pages a tab keeps alive under the one it shows. Going back to one of them (Back, or its sidebar row)
    /// shows it as it was in the next frame instead of building it again: a page of cards or tasks took 100-300 ms.
    static let keptLimit = 3

    /// The page Back would show in `tab`, kept alive under the tab's page when its view does not follow its
    /// resource (a folder, All Notes): going back then shows it again, scrolled where it was, instead of making it
    /// again during the motion back (a grid of cards took a quarter of a second, most frames of the motion late).
    /// Nil when there is no such page, or when it is shown by the same kind of view as the tab's page.
    func keptPages(of tab: Tab, in views: ViewRegistryStore) -> [(tab: Tab, context: ViewContext)] {
        let shownType = Self.viewType(for: tab, in: views)?.id
        var pages: [(tab: Tab, context: ViewContext)] = []
        var seen: Set<Resource> = [tab.resource]
        var types: Set<String> = shownType.map { [$0] } ?? []
        for previous in (history[tab.id] ?? []).reversed() where pages.count < Self.keptLimit {
            guard seen.insert(previous).inserted else { continue }
            let page = Tab(id: tab.id, resource: previous)
            // One page per kind of view: two of a kind would share the view's identity.
            guard let type = Self.viewType(for: page, in: views), !type.followsResource,
                  types.insert(type.id).inserted else { continue }
            let context: ViewContext
            if let kept = keptContexts[tab.id]?.first(where: { $0.resource == previous }) {
                context = kept
            } else {
                context = ViewContext(resource: previous, isActive: false)
                keep(context, in: tab.id)
            }
            pages.append((page, context))
        }
        // The oldest first, so the most recent lies right under the page shown.
        return pages.reversed()
    }

    private func keep(_ context: ViewContext, in tab: TabID) {
        var list = keptContexts[tab, default: []].filter { $0.resource != context.resource }
        list.append(context)
        keptContexts[tab] = Array(list.suffix(Self.keptLimit + 1))
    }

    /// The view type that shows `tab`: the one picked with "Open with" if it is still registered and can open the
    /// resource, else the highest priority one; nil when no installed plugin can open it.
    public static func viewType(for tab: Tab, in registry: ViewRegistryStore) -> ViewType? {
        if let chosen = tab.viewType,
           let type = registry.all.first(where: { $0.id == chosen }), type.canOpen(tab.resource) {
            return type
        }
        return registry.viewTypes(for: tab.resource).first
    }

    /// A picture of a pane's page as it is on screen, or nil when the window cannot draw it. Taken from the page's
    /// layers as they are, without drawing the views again: `cacheDisplay` over the window redrew every view under
    /// the pane and held the drag's start for a third of a second.
    func snapshot(of pane: PaneID) -> NSImage? {
        guard let window = NSApp.keyWindow, let host = window.contentView.flatMap({ Self.host(of: pane, in: $0) }),
              let layer = host.page.layer else { return nil }
        let size = host.page.bounds.size
        // At the drag thumbnail's size, not the page's: a tenth of the pixels to render.
        let scale = min(window.backingScaleFactor, DragThumbnail.width * window.backingScaleFactor / max(size.width, 1))
        guard size.width > 1, size.height > 1, let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        // The bitmap's origin is its bottom left; a flipped view's layer draws from the top left.
        if host.page.isFlipped {
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
        }
        (layer.presentation() ?? layer).render(in: cg)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    private static func host(of pane: PaneID, in view: NSView) -> PaneHostView? {
        if let host = view as? PaneHostView, host.pane == pane { return host }
        for subview in view.subviews { if let host = host(of: pane, in: subview) { return host } }
        return nil
    }

    // MARK: Changes

    func update(_ body: (inout WorkspaceLayout) -> Void) {
        var changed = layout
        let leaving = layout.activeTab?.id
        let leavingNewTab = leaving.map { isUntouchedNewTab($0, in: layout) } ?? false
        body(&changed)
        // An untouched new tab is discarded as soon as another tab is active, whatever the way there (a click,
        // opening a note that is already open, Back), as in Craft.
        if let leaving, changed.activeTab?.id != leaving, isUntouchedNewTab(leaving, in: changed) {
            changed.close(leaving)
        }
        guard changed != layout else { return }
        let moves = recordPageChanges(from: layout, to: changed)
            || changed.panes.map(\.id) != layout.panes.map(\.id)
            || changed.panes.map { $0.tabs.map(\.id) } != layout.panes.map { $0.tabs.map(\.id) }
        if moves { holdWindowWhilePagesMove() }
        // A pane coming or going: the others make room for it, or take the room it leaves.
        if changed.panes.map(\.id) != layout.panes.map(\.id) {
            Motion.with(Motion.Spring.standard.animation) { layout = changed }
        } else {
            layout = changed
        }
        syncContexts()
        let active = layout.activeTab?.resource
        if active != lastActive {
            lastActive = active
            onActiveResourceChange?(active)
        }
        if leavingNewTab, changed.activeTab?.id != leaving { onNewTabLeft?() }
        onChange?()
    }

    /// Called with true when pages, tabs or panes start to move, and with false once they have settled; the window
    /// is held still meanwhile (`TrafficLightsView`). Set by the window.
    @ObservationIgnored public var onPagesMoving: ((Bool) -> Void)?
    @ObservationIgnored private var pageMoveGeneration = 0

    /// Whether a split divider is being dragged: the window is held still meanwhile (`TrafficLightsView`).
    public private(set) var isDividerDragging = false

    public func dividerDragChanged(_ dragging: Bool) {
        if isDividerDragging != dragging { isDividerDragging = dragging }
    }

    /// Called with true while the pointer is over a tab or Home in a tab bar, false once it leaves them; the window
    /// is held still meanwhile (`TrafficLightsView`). Set by the window.
    @ObservationIgnored public var onPointerOverTabs: ((Bool) -> Void)?
    @ObservationIgnored private var panesUnderPointer: Set<PaneID> = []

    /// The pointer went over the tabs of `pane`'s bar, or left them (`TabBarView`).
    func pointerOverTabsChanged(_ over: Bool, in pane: PaneID) {
        let wasOver = !panesUnderPointer.isEmpty
        if over { panesUnderPointer.insert(pane) } else { panesUnderPointer.remove(pane) }
        if wasOver != !panesUnderPointer.isEmpty { onPointerOverTabs?(!panesUnderPointer.isEmpty) }
    }

    /// A movable window has AppKit work out again, on every frame something moves under its title bar, which parts
    /// of it drag the window; SwiftUI answers by tracing every interactive view there. A tab opening or closing, or a
    /// page arriving with its motion, held for the length of the motion.
    private func holdWindowWhilePagesMove() {
        pageMoveGeneration += 1
        let generation = pageMoveGeneration
        onPagesMoving?(true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.pageMoveGeneration == generation else { return }
            self.onPagesMoving?(false)
        }
    }

    /// Notes why each pane's page changed, before the layout it shows is replaced. True when a page arrives with a
    /// motion (anything but a page replaced in place).
    @discardableResult
    private func recordPageChanges(from old: WorkspaceLayout, to new: WorkspaceLayout) -> Bool {
        var moves = false
        let before = PaneSnapshot.of(old), after = PaneSnapshot.of(new)
        let focused = new.focusedPane
        pageChanges = pageChanges.filter { after[$0.key] != nil }
        for (pane, snapshot) in after {
            guard let previous = before[pane],
                  let kind = PageChange.between(
                      previous, snapshot,
                      origin: pane == focused ? change?.origin : nil,
                      isBack: pane == focused && change?.isBack == true
                  ),
                  let key = snapshot.key else { continue }
            pageChanges[pane] = (key, kind)
            if kind != .replaced {
                pageGenerations[key.tab, default: 0] += 1
                moves = true
            }
        }
        return moves
    }

    private func updateChrome(_ new: WorkspaceChrome) {
        guard new != chrome else { return }
        chrome = new
        onChange?()
    }

    /// Drops the contexts of closed or retargeted tabs and moves `isActive` to the focused tab.
    private func syncContexts() {
        var resources: [TabID: Resource] = [:]
        for pane in layout.panes { for tab in pane.tabs { resources[tab.id] = tab.resource } }
        // The context of a page that another replaced in its tab stays for that page, kept under it (`keptPages`);
        // going back to the kept page takes its context back.
        for (id, outgoing) in contexts where resources[id] != nil && resources[id] != outgoing.resource {
            if let index = keptContexts[id]?.firstIndex(where: { $0.resource == resources[id] }),
               let kept = keptContexts[id]?.remove(at: index) {
                kept.onStateChange = { [weak self] data in
                    MainActor.assumeIsolated { self?.update { $0.setState(data, for: id) } }
                }
                contexts[id] = kept
            } else {
                contexts[id] = nil
            }
            outgoing.isActive = false
            keep(outgoing, in: id)
        }
        keptContexts = keptContexts.filter { resources[$0.key] != nil }
        contexts = contexts.filter { resources[$0.key] == $0.value.resource }
        pageGenerations = pageGenerations.filter { resources[$0.key] != nil }
        newTabs = newTabs.filter { resources[$0.key] == $0.value }
        let active = layout.activeTab?.id
        for (id, context) in contexts where context.isActive != (id == active) {
            context.isActive = id == active
        }
    }
}
