import AppKit
import PluginKitUI
import SwiftUI
import WorkspaceModel
import XCTest
@testable import NotebookApp

/// The AppKit tab bar (`TabBarView`): its drops, driven with a dragging info, since `loam-ctl` cannot drag.
@MainActor
final class TabBarViewTests: ShellTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    /// A pane with tabs a, b and c, in a tree 1000 points wide.
    private func bar() async throws -> (WorkspaceController, TabBarView) {
        let session = try openSession()
        let workspace = session.workspace
        workspace.open(.virtual("test:a"), placement: .replace)
        workspace.open(.virtual("test:b"), placement: .newTab)
        workspace.open(.virtual("test:c"), placement: .newTab)
        let tree = SplitTreeView(workspace: workspace, views: session.views, environment: .standard)
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 1000, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        tree.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        window.contentView = tree
        tree.apply(workspace.layout.root, animated: false)
        self.window = window
        let bar = try XCTUnwrap(tree.panes.values.first?.tabs)
        try await waitUntil {
            tree.layoutSubtreeIfNeeded()
            bar.strip.layoutSubtreeIfNeeded()
            return bar.frames.value.count == 3
        }
        return (workspace, bar)
    }

    private func drag(_ payload: DragPayload, at x: CGFloat, in bar: TabBarView) -> FakeDrag {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loam-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data(payload.string.utf8), forType: TabBarView.dragType)
        let point = bar.convert(NSPoint(x: x, y: 20), to: nil)
        return FakeDrag(pasteboard: pasteboard, location: point, window: bar.window)
    }

    func testTheTabsAreAsWideAsTheirTitlesAndInOrder() async throws {
        let (workspace, bar) = try await bar()
        let tabs = try XCTUnwrap(workspace.layout.panes.first?.tabs)
        let frames = tabs.compactMap { bar.frames.value[$0.id] }
        XCTAssertEqual(frames.count, 3)
        XCTAssertLessThan(frames[0].maxX, frames[1].minX)
        XCTAssertLessThan(frames[1].maxX, frames[2].minX)
        XCTAssertGreaterThanOrEqual(bar.strip.frame.width, frames[2].maxX, "the strip holds every tab")
        XCTAssertLessThan(bar.strip.frame.width, 1000, "and is no wider than its tabs")
    }

    func testANoteDroppedInTheGapBetweenTwoTabsOpensThere() async throws {
        let (workspace, bar) = try await bar()
        let tabs = try XCTUnwrap(workspace.layout.panes.first?.tabs)
        let gap = try XCTUnwrap(bar.frames.value[tabs[1].id]).minX - 2
        let x = bar.convert(NSPoint(x: gap, y: 0), from: bar.strip).x
        let info = drag(.resource(.virtual("test:d")), at: x, in: bar)
        XCTAssertEqual(bar.draggingEntered(info), .move)
        XCTAssertEqual(bar.draggingUpdated(info), .move)
        XCTAssertTrue(bar.performDragOperation(info))
        try await waitUntil { workspace.layout.panes.first?.tabs.count == 4 }
        let names = workspace.layout.panes.first?.tabs.map(\.resource.path)
        XCTAssertEqual(names, ["test:a", "test:d", "test:b", "test:c"])
    }

    func testADropOnTheEmptyAreaGoesAtTheEnd() async throws {
        let (workspace, bar) = try await bar()
        let info = drag(.resource(.virtual("test:d")), at: 900, in: bar)
        XCTAssertTrue(bar.performDragOperation(info))
        try await waitUntil { workspace.layout.panes.first?.tabs.count == 4 }
        XCTAssertEqual(workspace.layout.panes.first?.tabs.last?.resource.path, "test:d")
    }

    func testSomethingElseIsRefused() async throws {
        let (_, bar) = try await bar()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loam-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        let info = FakeDrag(pasteboard: pasteboard, location: .zero, window: bar.window)
        XCTAssertEqual(bar.draggingEntered(info), [])
        XCTAssertFalse(bar.performDragOperation(info))
    }
}

extension TabBarViewTests {
    /// The page's own drop target (`PaneHostView`): its zones come with a drag, and a drop on an edge opens beside.
    func testANoteDroppedOnThePagesTrailingEdgeOpensBeside() async throws {
        let (workspace, bar) = try await bar()
        let host = try XCTUnwrap(bar.superview as? PaneHostView)
        DragSession.shared.begin(.resource(.virtual("test:d")))
        defer { DragSession.shared.end() }
        try await waitUntil { host.subviews.contains { $0 is NSHostingView<PaneDropZones> } }
        let page = host.page.frame
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loam-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data(DragPayload.resource(.virtual("test:d")).string.utf8), forType: TabBarView.dragType)
        let point = host.convert(NSPoint(x: page.maxX - 20, y: page.midY), to: nil)
        let info = FakeDrag(pasteboard: pasteboard, location: point, window: host.window)
        XCTAssertEqual(host.draggingEntered(info), .move)
        XCTAssertEqual(host.draggingUpdated(info), .move)
        XCTAssertTrue(host.performDragOperation(info))
        try await waitUntil { workspace.layout.panes.count == 2 }
        XCTAssertEqual(workspace.layout.panes.last?.tabs.first?.resource.path, "test:d")
        XCTAssertFalse(DragSession.shared.isActive, "the drop ends the drag")
    }
}

/// A drag over a view, as AppKit describes one to its destination.
@MainActor
final class FakeDrag: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?

    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow?) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingDestinationWindow = window
    }

    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
