import AppKit
import PluginKitUI
import SwiftUI
import XCTest
@testable import NotebookApp

/// A pane is drawn in a hosting view of its own (`PaneHostView`), which starts from SwiftUI's default environment: a
/// plugin's page must still read everything the window gives it.
@MainActor
final class PaneHostTests: ShellTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows = []
        EnvironmentProbe.seen = nil
        EnvironmentProbe.firstLine = nil
        try await super.tearDown()
    }

    private func render(_ session: ShellSession, appearance: NSAppearance.Name = .aqua) -> NSView {
        let size = CGSize(width: 1000, height: 700)
        let hosting = NSHostingView(rootView: ShellWindow(session: session))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        return hosting
    }

    /// A window as the app's: titled, its content under a transparent title bar. AppKit pushes a scroll view in
    /// the title bar row down by the title bar's height unless told not to.
    private func renderTitled(_ session: ShellSession) -> NSView {
        let size = CGSize(width: 1000, height: 700)
        let hosting = NSHostingView(rootView: ShellWindow(session: session))
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // A title bar as tall as the app's (52 points), over the top of the pages.
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        return hosting
    }

    func testTheTabsSitInTheirBarUnderATitleBar() async throws {
        let session = try openSession()
        session.workspace.open(.virtual("test:a"), placement: .replace)
        let view = renderTitled(session)
        let bar = try XCTUnwrap(view.firstSubview(of: TabBarView.self))
        let tab = try XCTUnwrap(session.workspace.layout.panes.first?.selected)
        try await waitUntil {
            view.layoutSubtreeIfNeeded()
            return bar.frames.value[tab] != nil
        }
        let frame = bar.convert(try XCTUnwrap(bar.frames.value[tab]), from: bar.strip)
        // The tab's capsule is 30 points tall, 5 from the bar's top: a title bar's inset pushed it below the bar, and
        // the selected tab showed an empty capsule over the page.
        XCTAssertEqual(frame.minY, 5, accuracy: 1, "the tab sits in its bar")
        XCTAssertLessThanOrEqual(frame.maxY, TabBar.height)
    }

    /// A press on a tab in the title bar row drags the tab, not the window: the window server moves the window from
    /// a press on any view there that says it can (`mouseDownCanMoveWindow`), before the app sees the press.
    func testDraggingATabInTheTitleBarRowDragsTheTabNotTheWindow() async throws {
        let session = try openSession()
        session.workspace.open(.virtual("test:a"), placement: .replace)
        session.workspace.open(.virtual("test:b"), placement: .newTab)
        let view = renderTitled(session)
        let window = try XCTUnwrap(view.window)
        let bar = try XCTUnwrap(view.firstSubview(of: TabBarView.self))
        let tab = try XCTUnwrap(session.workspace.layout.panes.first?.tabs.first?.id)
        try await waitUntil {
            view.layoutSubtreeIfNeeded()
            return bar.frames.value[tab] != nil
        }
        let frame = bar.convert(try XCTUnwrap(bar.frames.value[tab]), from: bar.strip)
        let point = bar.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        XCTAssertLessThan(view.bounds.height - point.y, 52, "the tab is in the title bar row")

        // No view of the shell's from the tab up to the workspace lets the window server take the press: AppKit leaves
        // out of the title bar's drag region every view that says no, whatever SwiftUI's views around it say.
        let tree = try XCTUnwrap(view.firstSubview(of: SplitTreeView.self))
        var hit = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point)
        var movers: [String] = []
        while let current = hit, current !== tree.superview {
            if current.mouseDownCanMoveWindow { movers.append(String(describing: type(of: current))) }
            hit = current.superview
        }
        XCTAssertEqual(movers, [], "views that would move the window from a tab")

        // A real press and drag on the tab starts a tab drag, and the window stays where it is.
        let before = window.frame
        func mouse(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        // The drag's moves and release go in the queue first: a drag session reads them in its own loop.
        for step in 1...6 {
            let moved = NSPoint(x: point.x + CGFloat(step) * 8, y: point.y - CGFloat(step) * 10)
            NSApplication.shared.postEvent(mouse(.leftMouseDragged, moved), atStart: false)
        }
        NSApplication.shared.postEvent(mouse(.leftMouseUp, NSPoint(x: point.x + 48, y: point.y - 60)), atStart: false)
        var dragged: DragPayload?
        let started = DragSession.shared.payload
        window.sendEvent(mouse(.leftMouseDown, point))
        // Drain what is left of the queue to the window, as the app's loop would.
        while let event = NSApplication.shared.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.2), inMode: .default, dequeue: true) {
            window.sendEvent(event)
            if dragged == nil, let payload = DragSession.shared.payload, payload != started { dragged = payload }
        }
        dragged = dragged ?? DragSession.shared.payload
        XCTAssertEqual(dragged, .tab(tab.raw), "the tab is dragged")
        XCTAssertEqual(window.frame, before, "the window did not move")
        DragSession.shared.end()
    }

    func testAPagesScrollingContentStartsUnderTheToolbar() async throws {
        let session = try openSession(ui: [ShellTestPlugin.self, ProbePlugin.self])
        session.workspace.open(.virtual("probe:scroll"), placement: .replace)
        let view = renderTitled(session)
        try await waitUntil {
            view.layoutSubtreeIfNeeded()
            return EnvironmentProbe.firstLine != nil
        }
        // Settled: the window's title bar is laid out a turn later.
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        // From the page's top: the toolbar's room comes through the page's safe area into its scroll views.
        let page = try XCTUnwrap(view.firstSubview(of: PageChromeView.self))
        let pageTop = page.convert(page.bounds, to: nil).maxY
        let windowHeight = try XCTUnwrap(view.window?.contentView?.bounds.height)
        let top = try XCTUnwrap(EnvironmentProbe.firstLine) - (windowHeight - pageTop)
        XCTAssertGreaterThanOrEqual(top, PageToolbar.height, "the first line is below the toolbar, not under it")
        XCTAssertLessThan(top, PageToolbar.height + 20)
    }

    func testAPluginPageReadsTheWindowsEnvironment() async throws {
        let session = try openSession(ui: [ShellTestPlugin.self, ProbePlugin.self])
        session.workspace.open(.virtual("probe:a"), placement: .replace)
        try session.themes.setAppearance(.dark)
        let view = render(session, appearance: .darkAqua)
        try await waitUntil { EnvironmentProbe.seen != nil }
        view.layoutSubtreeIfNeeded()
        let seen = try XCTUnwrap(EnvironmentProbe.seen)

        XCTAssertNotNil(view.firstSubview(of: PaneHostView.self), "the page is in a pane's own hosting view")
        XCTAssertEqual(seen.colorScheme, .dark, "colorScheme")
        XCTAssertNotEqual(seen.themeTokens, .standard, "themeTokens: the window's theme, not the default")
        let palette = session.themes.tokens(systemIsDark: true).palette
        XCTAssertEqual(seen.themeTokens.palette.accent, palette.accent ?? Glass.defaultAccentColor, "themeTokens: the window's accent")
        XCTAssertEqual(seen.scrollEdgeBackdrop, seen.themeTokens.background, "scrollEdgeBackdrop: the page's colour")
        XCTAssertEqual(seen.pageChromeInset, PageToolbar.height, "pageChromeInset: the toolbar's room")
        XCTAssertFalse(seen.sidebarSliding, "sidebarSliding")
        XCTAssertNotNil(seen.sidebarEdges, "sidebarEdges: set by the window")
        XCTAssertEqual(seen.tabBarTrailingInset, 44, "tabBarTrailingInset: room for the right sidebar button")
        XCTAssertTrue(seen.hasNewNote == (session.runtime.kernel.commands.command(id: "explorer.new-note") != nil), "pageActions")
        XCTAssertEqual(seen.windowCanvas != nil, palette.sidebar != nil || palette.background != nil, "windowCanvas")
    }

    func testThePaneFollowsAChangeOfTheWindowsEnvironment() async throws {
        let session = try openSession(ui: [ShellTestPlugin.self, ProbePlugin.self])
        session.workspace.open(.virtual("probe:a"), placement: .replace)
        let view = render(session)
        try await waitUntil { EnvironmentProbe.seen != nil }
        // A new accent, as Settings sets it: the theme's tokens reach the pane's own hosting view.
        let accent = ThemeColor(hex: "#FF2D55")!
        try session.themes.setAccent(accent)
        try await waitUntil {
            view.layoutSubtreeIfNeeded()
            return EnvironmentProbe.seen?.themeTokens.palette.accent == accent
        }
    }

    /// A view type with an AppKit view (`ViewType.makeNSView`) is shown as that view, with no hosting view between it
    /// and the page, and told the window's theme and the toolbar's room, then their changes.
    func testAnAppKitPageIsShownWithoutAHostingViewAndFollowsTheTheme() async throws {
        let session = try openSession(ui: [ShellTestPlugin.self, ProbePlugin.self])
        session.workspace.open(.virtual("native:a"), placement: .replace)
        let view = render(session)
        try await waitUntil {
            view.layoutSubtreeIfNeeded()
            return view.firstSubview(of: NativeProbeView.self) != nil
        }
        let native = try XCTUnwrap(view.firstSubview(of: NativeProbeView.self))
        let page = try XCTUnwrap(native.superview as? PageView, "the page holds the view itself")
        XCTAssertEqual(native.frame, page.bounds)
        XCTAssertEqual(native.seen?.topInset, PageToolbar.height)
        let accent = ThemeColor(hex: "#FF2D55")!
        try session.themes.setAccent(accent)
        try await waitUntil {
            view.layoutSubtreeIfNeeded()
            return native.seen?.theme.palette.accent == accent
        }
    }
}

/// An AppKit page that records what its host tells it.
private final class NativeProbeView: NSView, NativeHostedView {
    var seen: NativeViewEnvironment?
    func hostEnvironmentChanged(_ environment: NativeViewEnvironment) { seen = environment }
}

/// What the probe page last read from its environment.
@MainActor
enum EnvironmentProbe {
    struct Seen {
        var colorScheme: ColorScheme
        var themeTokens: ThemeTokens
        var scrollEdgeBackdrop: Color?
        var pageChromeInset: CGFloat
        var sidebarSliding: Bool
        var sidebarEdges: SidebarEdges?
        var tabBarTrailingInset: CGFloat
        var hasNewNote: Bool
        var windowCanvas: Color?
    }

    static var seen: Seen?
    /// Where a scrolling page's first line is, from the page's top.
    static var firstLine: CGFloat?
}

/// A page that scrolls, as All Notes does (a scroll view in a geometry reader): its first line reports where it is.
private struct ScrollProbeView: View {
    var body: some View {
        GeometryReader { _ in
            ScrollView {
                Text("First line")
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { EnvironmentProbe.firstLine = $0 }
                ForEach(0..<40, id: \.self) { Text("Line \($0)") }
            }
        }
    }
}

private struct ProbeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeTokens) private var themeTokens
    @Environment(\.scrollEdgeBackdrop) private var scrollEdgeBackdrop
    @Environment(\.pageChromeInset) private var pageChromeInset
    @Environment(\.sidebarSliding) private var sidebarSliding
    @Environment(\.sidebarEdges) private var sidebarEdges
    @Environment(\.tabBarTrailingInset) private var tabBarTrailingInset
    @Environment(\.pageActions) private var pageActions
    @Environment(\.windowCanvas) private var windowCanvas
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let seen = EnvironmentProbe.Seen(
            colorScheme: colorScheme, themeTokens: themeTokens, scrollEdgeBackdrop: scrollEdgeBackdrop,
            pageChromeInset: pageChromeInset, sidebarSliding: sidebarSliding, sidebarEdges: sidebarEdges,
            tabBarTrailingInset: tabBarTrailingInset, hasNewNote: pageActions.newNote != nil, windowCanvas: windowCanvas
        )
        Text("Probe")
            .onAppear { EnvironmentProbe.seen = seen }
            .onChange(of: themeTokens) { EnvironmentProbe.seen = seen }
            .onChange(of: colorScheme) { EnvironmentProbe.seen = seen }
    }
}

private final class ProbePlugin: UIPlugin {
    static let manifest = PluginManifest(id: "test.probe", name: "Probe", version: "1.0")

    init() {}

    @MainActor func activateUI(context: PluginContext) throws {
        try context.registerView(ViewType(
            id: "test.probe",
            title: "Probe",
            canOpen: { $0.kind == .virtual && $0.path.hasPrefix("probe:") },
            makeView: { context in
                AnyView(Group {
                    if context.resource.path == "probe:scroll" { ScrollProbeView() } else { ProbeView() }
                })
            }
        ))
        var native = ViewType(
            id: "test.native",
            title: "Native",
            canOpen: { $0.kind == .virtual && $0.path.hasPrefix("native:") },
            makeView: { _ in AnyView(NativeView { NativeProbeView() }) }
        )
        native.makeNSView = { _ in NativeProbeView() }
        try context.registerView(native)
    }
}

extension NSView {
    /// The first view of `type` under this one, depth first.
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}
