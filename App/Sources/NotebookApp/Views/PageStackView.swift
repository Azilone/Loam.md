import AppKit
import Observation
import PluginKitUI
import SwiftUI
import WorkspaceModel

/// A pane's page in AppKit: the selected tab's view, the pages it keeps under it (`WorkspaceController.keptPages`),
/// and the page's toolbar over them. Each page is a hosting view of its own, and a page arriving or leaving moves as
/// a Core Animation layer (`PageChange`: from the clicked card, from the side of the new tab, back to where it came
/// from), so the motion runs in the render server at the display's rate whatever the page holds.
///
/// The pages were a SwiftUI stack with SwiftUI transitions: each frame of a page's arrival laid the page out again on
/// the main thread, and a note's text was drawn again at each step of its scale. A new tab or a note opened from a
/// card ran at 20-35 frames a second.
final class PageStackView: NSView {
    private let pane: PaneID
    private weak var workspace: WorkspaceController?
    private let views: ViewRegistryStore
    var environment: PaneEnvironment { didSet { if environment != oldValue { environmentChanged(from: oldValue) } } }

    /// The toolbar over the pages: the page's text scrolls under its glass.
    private let toolbar: PageToolbar
    /// Focuses the pane on any click in it, even one a text view takes.
    private let clickDetector = PaneClickDetector.DetectorView()
    /// The pages alive, by the identity of their view; the shown one last among `order`.
    private var hosts: [TabContentView.Identity: PageView] = [:]
    private var order: [TabContentView.Identity] = []
    /// The page each of the last tabs left showed, hidden, by identity, the most recent last: going back to that tab
    /// (closing the one over it, ⌘1, a click on its tab) shows it again instead of building it (a note took ~130 ms).
    private var retained: [TabContentView.Identity: PageView] = [:]
    private var retainedOrder: [TabContentView.Identity] = []
    static let retainedLimit = 2
    /// A page no tab shows any more, hidden, by view type, ready for the next page of that type: the home page for the
    /// next new tab (⌘T, ~70 ms to build), the editor for the next note opened from a card (70-120 ms to build). Only
    /// for views that hold nothing of their own page: the home page, and the views that follow their resource
    /// (`ViewType.followsResource`), which a link already moves from note to note.
    private var spares: [String: PageView] = [:]
    static let reusedViewTypes: Set<String> = ["home.page"]

    /// The page of what the first sidebar row opens (All Notes: 90-270 ms to build the first time),
    /// built ahead once and handed to the first tab that shows it. Only for the view types that read nothing of their
    /// tab's context but its resource, so the page made with a context of its own is the same as the tab's.
    private var ready: (resource: Resource, viewType: String, host: PageView)?
    private var builtReady = false
    static let readyViewTypes: Set<String> = ["explorer.folder"]

    private func isReusable(_ identity: TabContentView.Identity) -> Bool {
        guard let type = identity.viewType else { return false }
        // A view that follows its resource has no resource in its identity.
        return Self.reusedViewTypes.contains(type) || identity.resource == nil
    }
    /// What the pane showed when the pages were last brought up to date: a new one is a page change.
    private var shownKey: PageKey?
    /// What a pane without a tab shows.
    private var emptyHost: PageHostingView<AnyView>?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(pane: PaneID, workspace: WorkspaceController, views: ViewRegistryStore, environment: PaneEnvironment) {
        self.pane = pane
        self.workspace = workspace
        self.views = views
        self.environment = environment
        toolbar = PageToolbar(pane: pane, workspace: workspace, views: views, environment: environment)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(toolbar)
        clickDetector.onMouseDown = { [weak self] in
            guard let self else { return }
            self.workspace?.focus(self.pane)
        }
        addSubview(clickDetector)
        sync(animated: false)
        observe()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Brings the pages up to date after each change of what the workspace shows in the pane.
    private func observe() {
        withObservationTracking {
            _ = desiredPages()
        } onChange: { [weak self] in
            // Told before the change is made: the pages follow once it is.
            DispatchQueue.main.async {
                guard let self else { return }
                self.sync(animated: true)
                self.observe()
            }
        }
    }

    private func environmentChanged(from old: PaneEnvironment) {
        toolbar.environment = environment
        for host in hosts.values { host.environment = environment }
        emptyHost?.rootView = emptyRoot()
        // Nothing on the page reacts to the pointer while a sidebar slides: every frame of the slide hit-tested each
        // hover area of the page again.
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        environment.sidebarSliding ? nil : super.hitTest(point)
    }

    // MARK: Pages

    private struct Desired {
        let tab: WorkspaceModel.Tab
        let context: ViewContext
        let identity: TabContentView.Identity
        let isKept: Bool
    }

    /// The selected tab's pages, the kept ones first; nil when the pane has no tab.
    private func desiredPages() -> [Desired]? {
        guard let workspace, let pane = workspace.layout.panes.first(where: { $0.id == pane }),
              let tab = pane.tabs.first(where: { $0.id == pane.selected }) else { return nil }
        let shown = Desired(
            tab: tab, context: workspace.context(for: tab),
            identity: TabContentView.Identity(tab: tab, views: views, workspace: workspace), isKept: false
        )
        var identities: Set<TabContentView.Identity> = [shown.identity]
        let kept = workspace.keptPages(of: tab, in: views).compactMap { kept -> Desired? in
            let identity = TabContentView.Identity(tab: kept.tab, views: views, workspace: workspace)
            guard identities.insert(identity).inserted else { return nil }
            return Desired(tab: kept.tab, context: kept.context, identity: identity, isKept: true)
        }
        return kept + [shown]
    }

    private func sync(animated: Bool) {
        guard let workspace else { return }
        guard let desired = desiredPages(), let shown = desired.last else {
            showEmpty()
            return
        }
        emptyHost?.removeFromSuperview()
        emptyHost = nil
        let key = PageKey(shown.tab)
        let change = workspace.pageChange(for: pane, showing: key)
        let isChange = shownKey != nil && shownKey != key
        shownKey = key
        let motion = animated && isChange && change != .replaced
        let previouslyShown = order.last

        // Pages that are no longer wanted leave: the one that was shown in the change's pose, the others at once. The
        // page of a tab that is still open is kept, hidden, for when that tab comes back.
        let wanted = Set(desired.map(\.identity))
        let openTabs = Set(workspace.layout.panes.first { $0.id == pane }?.tabs.map(\.id) ?? [])
        for (identity, host) in hosts where !wanted.contains(identity) {
            hosts[identity] = nil
            let keep = identity == previouslyShown && identity.tab != shown.identity.tab && openTabs.contains(identity.tab)
            if motion, identity == previouslyShown {
                let spareIt = !keep && isReusable(identity) && identity.viewType.map { spares[$0] == nil } == true
                if spareIt, let type = identity.viewType { spares[type] = host }
                leave(host, effect: workspace.pageEffect(for: pane, leaving: true), remove: !keep && !spareIt)
            } else if keep {
                host.retire()
            } else {
                discard(host, identity: identity)
            }
            if keep { retain(host, as: identity) }
        }
        // A tab closed takes its kept page with it.
        for (identity, host) in retained where !openTabs.contains(identity.tab) {
            host.removeFromSuperview()
            retained[identity] = nil
            retainedOrder.removeAll { $0 == identity }
        }

        // The wanted pages, made when new, in order under the toolbar: the kept ones, then the shown one.
        var arriving: PageView?
        for page in desired {
            let host: PageView
            if let existing = hosts[page.identity] {
                host = existing
                host.show(tab: page.tab, context: page.context)
            } else if let kept = takeRetained(page.identity) {
                host = kept
                host.environment = environment
                host.revive()
                host.show(tab: page.tab, context: page.context)
                hosts[page.identity] = host
                if !page.isKept { arriving = host }
            } else if isReusable(page.identity), let type = page.identity.viewType, let spare = spares.removeValue(forKey: type) {
                host = spare
                host.environment = environment
                host.revive()
                host.show(tab: page.tab, context: page.context)
                hosts[page.identity] = host
                if !page.isKept { arriving = host }
            } else if let built = ready, built.resource == page.tab.resource, built.viewType == page.identity.viewType {
                ready = nil
                host = built.host
                host.environment = environment
                host.revive()
                host.show(tab: page.tab, context: page.context)
                hosts[page.identity] = host
                if !page.isKept { arriving = host }
            } else {
                host = PageView(views: views, environment: environment)
                host.show(tab: page.tab, context: page.context)
                hosts[page.identity] = host
                if !page.isKept { arriving = host }
            }
            host.setKept(page.isKept)
            addSubview(host, positioned: .below, relativeTo: toolbar)
        }
        order = desired.map(\.identity)
        layoutPages()
        if motion, let arriving, previouslyShown != nil {
            arrive(arriving, effect: workspace.pageEffect(for: pane, leaving: false), change: change)
        }
        scheduleAhead()
    }

    /// The page kept for `identity`'s tab, whatever page generation it was shown at: a click on a tab is a page change,
    /// which gives a view that follows its resource a new generation, and the page kept for that tab was never found.
    private func takeRetained(_ identity: TabContentView.Identity) -> PageView? {
        guard let key = retainedOrder.last(where: {
            $0.tab == identity.tab && $0.viewType == identity.viewType && $0.resource == identity.resource
        }) else { return nil }
        retainedOrder.removeAll { $0 == key }
        return retained.removeValue(forKey: key)
    }

    /// A page no longer shown anywhere: gone, or kept as the spare of its view type.
    private func discard(_ host: PageView, identity: TabContentView.Identity) {
        guard isReusable(identity), let type = identity.viewType, spares[type] == nil else {
            host.removeFromSuperview()
            return
        }
        host.retire()
        spares[type] = host
    }

    private func retain(_ host: PageView, as identity: TabContentView.Identity) {
        retained[identity] = host
        retainedOrder.removeAll { $0 == identity }
        retainedOrder.append(identity)
        while retainedOrder.count > Self.retainedLimit {
            let oldest = retainedOrder.removeFirst()
            retained.removeValue(forKey: oldest)?.removeFromSuperview()
        }
    }

    /// A pane without a tab: the home page opens in it, or it says it is empty.
    private func showEmpty() {
        for host in Array(hosts.values) + Array(retained.values) + Array(spares.values) { host.removeFromSuperview() }
        ready?.host.removeFromSuperview()
        ready = nil
        spares = [:]
        hosts = [:]
        retained = [:]
        retainedOrder = []
        order = []
        shownKey = nil
        if let home = environment.pageActions.home {
            workspace?.open(home, placement: .replace)
            // Opened during a sync, before `observe` is armed again: that change is never told, and the home page
            // was never made (a blank pane after ⌘W on the last tab). It is shown now.
            if desiredPages() != nil { sync(animated: false) }
            return
        }
        if emptyHost == nil {
            let host = PageHostingView(rootView: emptyRoot())
            host.safeAreaRegions = []
            host.sizingOptions = []
            addSubview(host, positioned: .below, relativeTo: toolbar)
            emptyHost = host
            needsLayout = true
        }
    }

    private func emptyRoot() -> AnyView {
        AnyView(EmptyPaneView().paneEnvironment(environment))
    }

    // MARK: Pages built ahead

    /// When the app last had a key, a click or a scroll: pages are built ahead only once it has been still for
    /// `idleDelay`, so no build lands under a person's hands.
    private static var lastInput = ProcessInfo.processInfo.systemUptime
    private static var inputMonitor: Any?
    static let idleDelay = 1.0
    private var aheadWork: DispatchWorkItem?
    /// The notes edited last, asked of the session once (nil until they come): the editor is built ahead on one.
    private var recentNotes: [Resource]?
    private var askedRecentNotes = false

    private static func watchInput() {
        guard inputMonitor == nil else { return }
        let kinds: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .scrollWheel]
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: kinds) { event in
            MainActor.assumeIsolated { lastInput = ProcessInfo.processInfo.systemUptime }
            return event
        }
    }

    /// Builds, hidden, what the next first-time action would build, one page per pass: an editor on a recent note
    /// (the first note opened took 70-120 ms), the home page (the first ⌘T, ~70 ms) and the page of the tabs next to
    /// the shown one (the first click on a tab restored at launch built it). Each pass waits until the app has had no
    /// input for `idleDelay` and nothing moves; what it builds is only the spare of its view type
    /// (`spares`) or a page kept for its tab (`retained`), within their limits.
    private func scheduleAhead(after delay: Double = 1.5) {
        aheadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.buildAhead() }
        aheadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func buildAhead() {
        aheadWork = nil
        guard let workspace else { return }
        Self.watchInput()
        if !askedRecentNotes, let recent = workspace.recentNotes {
            askedRecentNotes = true
            Task { [weak self] in
                let notes = await recent()
                self?.recentNotes = notes
                self?.scheduleAhead(after: 0.25)
            }
        }
        let still = ProcessInfo.processInfo.systemUptime - Self.lastInput
        guard window != nil, !bounds.isEmpty, still >= Self.idleDelay, !isMoving else {
            scheduleAhead(after: max(0.25, Self.idleDelay - still))
            return
        }
        guard let next = nextAhead() else { return }
        next()
        scheduleAhead(after: 0.25)
    }

    /// Whether a page or a sidebar is moving: nothing is built under a motion.
    private var isMoving: Bool {
        environment.sidebarSliding || subviews.contains { view in
            guard let page = view as? PageView, !page.isHidden else { return false }
            return page.isLeaving || page.layer?.animationKeys()?.isEmpty == false
        }
    }

    /// The next page to build ahead, nil once there is none.
    private func nextAhead() -> (() -> Void)? {
        guard let workspace, let paneTabs = workspace.layout.panes.first(where: { $0.id == pane }) else { return nil }
        for note in recentNotes ?? [] {
            let tab = WorkspaceModel.Tab(id: TabID(raw: UUID()), resource: note)
            guard let type = WorkspaceController.viewType(for: tab, in: views), type.followsResource else { continue }
            if spares[type.id] != nil { break }
            return { [weak self] in
                guard let self else { return }
                self.spares[type.id] = self.buildHidden(tab, context: ViewContext(resource: note, isActive: false))
            }
        }
        if let home = workspace.newTabResource?() {
            let tab = WorkspaceModel.Tab(id: TabID(raw: UUID()), resource: home)
            if let type = WorkspaceController.viewType(for: tab, in: views),
               Self.reusedViewTypes.contains(type.id) || type.followsResource, spares[type.id] == nil {
                return { [weak self] in
                    guard let self else { return }
                    self.spares[type.id] = self.buildHidden(tab, context: ViewContext(resource: home, isActive: false))
                }
            }
        }
        if !builtReady, let home = workspace.firstLink?(), !hosts.keys.contains(where: { $0.resource == home }) {
            let tab = WorkspaceModel.Tab(id: TabID(raw: UUID()), resource: home)
            if let type = WorkspaceController.viewType(for: tab, in: views), Self.readyViewTypes.contains(type.id) {
                return { [weak self] in
                    guard let self else { return }
                    self.builtReady = true
                    let host = self.buildHidden(tab, context: ViewContext(resource: home, isActive: false))
                    self.ready = (home, type.id, host)
                }
            }
        }
        // The tabs nearest the shown one first, while there is room among the kept pages.
        guard retained.count < Self.retainedLimit, let selected = paneTabs.tabs.firstIndex(where: { $0.id == paneTabs.selected })
        else { return nil }
        let others = paneTabs.tabs.indices.filter { $0 != selected }.sorted { abs($0 - selected) < abs($1 - selected) }
        for index in others.prefix(Self.retainedLimit) {
            let tab = paneTabs.tabs[index]
            guard !retained.keys.contains(where: { $0.tab == tab.id }), !hosts.keys.contains(where: { $0.tab == tab.id }),
                  WorkspaceController.viewType(for: tab, in: views) != nil else { continue }
            return { [weak self] in
                guard let self, let workspace = self.workspace else { return }
                let identity = TabContentView.Identity(tab: tab, views: self.views, workspace: workspace)
                let host = self.buildHidden(tab, context: workspace.context(for: tab))
                // Older than the pages tabs really left: those stay when the limit is reached.
                self.retained[identity] = host
                self.retainedOrder.insert(identity, at: 0)
            }
        }
        return nil
    }

    /// A page made and laid out at the pane's size under the others, drawn once there, then hidden as a kept page
    /// is; it takes no click meanwhile.
    private func buildHidden(_ tab: WorkspaceModel.Tab, context: ViewContext) -> PageView {
        let host = PageView(views: views, environment: environment)
        host.show(tab: tab, context: context)
        host.frame = bounds
        addSubview(host, positioned: .below, relativeTo: nil)
        host.layoutSubtreeIfNeeded()
        host.setKept(true)
        return host
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        layoutPages()
        toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PageToolbar.height)
        clickDetector.frame = bounds
        emptyHost?.frame = bounds
    }

    /// The shown page at the pane's size; a kept page keeps the size it was last shown at, so a resize does not lay
    /// it out again under the page (the home page kept under a note laid its cards out on every step).
    private func layoutPages() {
        for (identity, host) in hosts where !host.isKept || host.frame.isEmpty || identity == order.last {
            if host.frame != bounds { host.frame = bounds }
        }
    }

    // MARK: Motion

    /// The page arriving: from the change's pose to rest, faded in. A crossfade only fades; under Reduce Motion so
    /// does every change.
    private func arrive(_ host: PageView, effect: PageEffect, change: PageChange) {
        guard !effect.isInstant else { return }
        let reduce = Motion.reduceMotion
        let spring = change.springs
        let duration = spring ? Motion.Spring.smooth.duration : change.opensPage ? Motion.pageOpenDuration : PageStackView.crossfade
        host.animate(
            opacity: (0, 1), transform: (reduce ? .identity : effect, .identity),
            duration: duration, spring: spring && !reduce, completion: nil
        )
    }

    /// The page leaving: fades faster than one arrives (`Motion.exit`), toward the change's pose; gone once out, or
    /// hidden when it is kept for its tab (`remove` false).
    private func leave(_ host: PageView, effect: PageEffect, remove: Bool) {
        guard !effect.isInstant else {
            if remove { host.removeFromSuperview() } else { host.retire() }
            return
        }
        host.isLeaving = true
        addSubview(host, positioned: .below, relativeTo: toolbar)
        host.animate(
            opacity: (1, 0), transform: (.identity, Motion.reduceMotion ? .identity : effect),
            duration: PageStackView.exit, spring: false, easeIn: true
        ) { [weak host] in
            guard let host, host.isLeaving else { return }
            if remove { host.removeFromSuperview() } else { host.retire() }
        }
    }

    /// `Motion.crossfade` and `Motion.exit`'s lengths, for Core Animation.
    static let crossfade = 0.16
    static let exit = 0.12
}

private extension PageChange {
    /// Whether the change moves on a spring (`Motion.Spring.smooth`): only a view swapped in place.
    var springs: Bool { self == .swap }

    /// A page opened from somewhere, or Back: the short ease-out of `Motion.pageOpen`.
    var opensPage: Bool {
        switch self {
        case .opened, .back: true
        case .crossfade, .tab, .closed, .replaced, .swap: false
        }
    }
}

/// One page: the tab's view in a hosting view of its own, in the window's environment, or the view itself when its
/// type gives one in AppKit (`ViewType.makeNSView`). Its layer carries the page's motion (opacity and a transform of
/// what it holds), which Core Animation plays without the main thread.
final class PageView: NSView {
    private let host: PageHostingView<AnyView>
    private let views: ViewRegistryStore
    private var tab: WorkspaceModel.Tab?
    private weak var context: ViewContext?
    /// The type's AppKit view, for the context it was made with; the hosting view is then empty and hidden.
    private var native: (view: NSView, context: ViewContext, type: String)?
    var environment: PaneEnvironment { didSet { if environment != oldValue { rebuild() } } }
    private(set) var isKept = false
    var isLeaving = false
    private var hideWork: DispatchWorkItem?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(views: ViewRegistryStore, environment: PaneEnvironment) {
        self.views = views
        self.environment = environment
        host = PageHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        wantsLayer = true
        host.safeAreaRegions = []
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        if host.frame != bounds { host.frame = bounds }
        if let view = native?.view, view.frame != bounds { view.frame = bounds }
    }

    /// A kept page and a leaving one take no clicks: the page over it does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isKept || isLeaving ? nil : super.hitTest(point)
    }

    func show(tab: WorkspaceModel.Tab, context: ViewContext) {
        guard tab != self.tab || context !== self.context else { return }
        self.tab = tab
        self.context = context
        rebuild()
    }

    private func rebuild() {
        guard let tab, let context else { return }
        let theme = environment.themeTokens
        if let type = WorkspaceController.viewType(for: tab, in: views), let make = type.makeNSView {
            showNative(make, type: type.id, context: context, theme: theme)
            return
        }
        if let native {
            native.view.removeFromSuperview()
            self.native = nil
            layer?.backgroundColor = nil
            host.isHidden = false
        }
        host.rootView = AnyView(
            TabContentView(tab: tab, context: context, views: views)
                // The toolbar's room is given inside the page: the page's text scrolls up under the toolbar's glass.
                .safeAreaPadding(.top, PageToolbar.height)
                // Each page is opaque, so nothing of the page under it shows through its gaps.
                .background(theme.background)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .environment(\.pageChromeInset, PageToolbar.height)
                .environment(\.scrollEdgeBackdrop, theme.background)
                .paneEnvironment(environment)
        )
    }

    /// The type's AppKit view, made again only for a new context (a view that follows its resource gets the next
    /// note's): no hosting view, no SwiftUI between the page and its view.
    private func showNative(_ make: @MainActor (ViewContext) -> NSView, type: String, context: ViewContext, theme: ThemeTokens) {
        if native?.context !== context || native?.type != type {
            native?.view.removeFromSuperview()
            let view = make(context)
            view.frame = bounds
            addSubview(view)
            native = (view, context, type)
        }
        if !host.isHidden {
            host.isHidden = true
            host.rootView = AnyView(EmptyView())
        }
        // Each page is opaque, so nothing of the page under it shows through its gaps.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(theme.background).cgColor
        }
        (native?.view as? NativeHostedView)?.hostEnvironmentChanged(NativeViewEnvironment(theme: theme, topInset: PageToolbar.height))
    }

    /// Hidden and out of the way, kept for its tab.
    func retire() {
        isLeaving = false
        isKept = false
        hideWork?.cancel()
        isHidden = true
        layer?.removeAllAnimations()
        alphaValue = 1
        layer?.opacity = 1
        layer?.sublayerTransform = CATransform3DIdentity
    }

    /// Back from being kept for its tab, or from the spares: shown as it is at rest, whatever motion it was in. A page
    /// taken back while it was still leaving kept the leave's end (opacity 0, its completion skipped as it is no longer
    /// leaving), and showed nothing: the home page after ⌘W on a note opened from it.
    func revive() {
        isLeaving = false
        hideWork?.cancel()
        hideWork = nil
        layer?.removeAllAnimations()
        alphaValue = 1
        layer?.opacity = 1
        layer?.sublayerTransform = CATransform3DIdentity
        isHidden = false
    }

    /// A kept page stays drawn while the page opened from it arrives over it, then is hidden; shown again it is there
    /// at once.
    func setKept(_ kept: Bool) {
        guard kept != isKept || (!kept && isHidden) else { return }
        isKept = kept
        hideWork?.cancel()
        hideWork = nil
        if kept {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isKept else { return }
                self.isHidden = true
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        } else {
            isHidden = false
            layer?.removeAllAnimations()
            alphaValue = 1
            layer?.sublayerTransform = CATransform3DIdentity
        }
    }

    /// Plays a move of the page from one pose to another, as layer animations: the opacity on the page's layer, the
    /// scale and shift on what it holds (`sublayerTransform`, which AppKit leaves alone).
    func animate(
        opacity: (from: CGFloat, to: CGFloat), transform: (from: PageEffect, to: PageEffect),
        duration: Double, spring: Bool, easeIn: Bool = false, completion: (() -> Void)?
    ) {
        guard let layer else {
            completion?()
            return
        }
        let from = Self.transform(transform.from, in: bounds.size)
        let to = Self.transform(transform.to, in: bounds.size)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        CATransaction.setDisableActions(true)
        layer.opacity = Float(opacity.to)
        layer.sublayerTransform = to
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity.from
        fade.toValue = opacity.to
        fade.duration = spring ? min(duration, PageStackView.crossfade * 1.5) : duration
        fade.timingFunction = CAMediaTimingFunction(name: easeIn ? .easeIn : .easeOut)
        layer.add(fade, forKey: "pageFade")
        if !CATransform3DEqualToTransform(from, to) {
            let move: CABasicAnimation
            if spring {
                let settle = CASpringAnimation(perceptualDuration: duration, bounce: Motion.Spring.smooth.bounce)
                settle.duration = settle.settlingDuration
                move = settle
            } else {
                move = CABasicAnimation()
                move.duration = duration
                move.timingFunction = CAMediaTimingFunction(name: easeIn ? .easeIn : .easeOut)
            }
            move.keyPath = "sublayerTransform"
            move.fromValue = from
            move.toValue = to
            layer.add(move, forKey: "pageMove")
        }
        CATransaction.commit()
        // AppKit reads the view's alpha from here on: keep it in step with the layer.
        alphaValue = opacity.to
    }

    /// `effect` as a transform of a page of `size`: scaled about its anchor (a unit point, top left origin), then
    /// shifted.
    static func transform(_ effect: PageEffect, in size: CGSize) -> CATransform3D {
        let x = effect.anchor.x * size.width, y = effect.anchor.y * size.height
        var t = CATransform3DMakeTranslation(x + effect.offset.width, y + effect.offset.height, 0)
        t = CATransform3DScale(t, effect.scale, effect.scale, 1)
        return CATransform3DTranslate(t, -x, -y, 0)
    }
}
