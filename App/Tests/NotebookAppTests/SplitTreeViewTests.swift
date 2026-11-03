import AppKit
import PluginKitUI
import SwiftUI
import WorkspaceModel
import XCTest
@testable import NotebookApp

/// The workspace tree in AppKit (`SplitTreeView`): panes placed by the model's fractions, and the dividers' mouse
/// handling, driven with real events, since `loam-ctl` cannot drag a divider.
@MainActor
final class SplitTreeViewTests: ShellTestCase {
    private var window: NSWindow?

    override func setUp() async throws {
        try await super.setUp()
        Motion.reduceMotionOverride = true
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        Motion.reduceMotionOverride = nil
        try await super.tearDown()
    }

    /// Two panes side by side in a tree 1008 points wide: 500 points each, the 8 point gap between them.
    private func twoPanes() throws -> (WorkspaceController, SplitTreeView) {
        let session = try openSession()
        let workspace = session.workspace
        workspace.open(.virtual("test:a"), placement: .replace)
        workspace.open(.virtual("test:b"), placement: .beside)
        let tree = SplitTreeView(workspace: workspace, views: session.views, environment: EnvironmentValues())
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 1008, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        tree.frame = CGRect(x: 0, y: 0, width: 1008, height: 600)
        // Given before it is in the window, as SwiftUI does: the panes come once it is.
        tree.apply(workspace.layout.root, animated: false)
        XCTAssertTrue(tree.panes.isEmpty)
        window.contentView = tree
        self.window = window
        return (workspace, tree)
    }

    private func frames(_ tree: SplitTreeView, _ workspace: WorkspaceController) -> [CGRect] {
        tree.layoutSubtreeIfNeeded()
        return workspace.layout.panes.compactMap { tree.panes[$0.id]?.frame }
    }

    private func divider(_ tree: SplitTreeView) throws -> SplitDividerView {
        try XCTUnwrap(tree.dividers.values.first)
    }

    private func mouse(_ type: NSEvent.EventType, x: CGFloat, clicks: Int = 1, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: 300), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
        )!
    }

    func testThePanesArePlacedByTheFractionsWithTheGapBetweenThem() throws {
        let (workspace, tree) = try twoPanes()
        let placed = frames(tree, workspace)
        XCTAssertEqual(placed.count, 2)
        XCTAssertEqual(placed[0], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(placed[1], CGRect(x: 508, y: 0, width: 500, height: 600))
        let grip = try divider(tree).frame
        XCTAssertEqual(grip.midX, 504, "the divider's grip is centred on the gap")
        XCTAssertEqual(grip.height, 600)
    }

    func testDraggingTheDividerMovesThePagesOneForOneAndCommitsOnRelease() throws {
        let (workspace, tree) = try twoPanes()
        let divider = try divider(tree)
        let window = try XCTUnwrap(self.window)
        let before = workspace.layout.root
        divider.mouseDown(with: mouse(.leftMouseDown, x: 504, in: window))
        divider.mouseDragged(with: mouse(.leftMouseDragged, x: 404, in: window))
        XCTAssertTrue(workspace.isDividerDragging, "the window holds still while a divider is dragged")
        XCTAssertEqual(frames(tree, workspace)[0].width, 400, accuracy: 0.5)
        XCTAssertEqual(workspace.layout.root, before, "the model is written once, on release")
        divider.mouseUp(with: mouse(.leftMouseUp, x: 404, in: window))
        XCTAssertFalse(workspace.isDividerDragging)
        guard case .split(_, _, _, let fractions) = workspace.layout.root else { return XCTFail("a split") }
        XCTAssertEqual(fractions[0], 0.4, accuracy: 0.001)
        XCTAssertEqual(frames(tree, workspace)[0].width, 400, accuracy: 0.5, "no frame shows the pages where they were")
        tree.apply(workspace.layout.root, animated: false)
        XCTAssertEqual(frames(tree, workspace)[0].width, 400, accuracy: 0.5)
    }

    func testTheDividerIsHeldOnTheMiddleNearItAndLandsThere() throws {
        let (workspace, tree) = try twoPanes()
        let divider = try divider(tree)
        let window = try XCTUnwrap(self.window)
        divider.mouseDown(with: mouse(.leftMouseDown, x: 504, in: window))
        divider.mouseDragged(with: mouse(.leftMouseDragged, x: 400, in: window))
        // Back to 3 points from the middle: held on it.
        divider.mouseDragged(with: mouse(.leftMouseDragged, x: 507, in: window))
        XCTAssertEqual(frames(tree, workspace)[0].width, 500, accuracy: 0.5)
        // Let go 10 points from the middle: it lands on it.
        divider.mouseDragged(with: mouse(.leftMouseDragged, x: 514, in: window))
        divider.mouseUp(with: mouse(.leftMouseUp, x: 514, in: window))
        guard case .split(_, _, _, let fractions) = workspace.layout.root else { return XCTFail("a split") }
        XCTAssertEqual(fractions[0], 0.5, accuracy: 0.0001)
    }

    func testADoubleClickEvensThePagesOutAndTheNextOneGoesBack() throws {
        let (workspace, tree) = try twoPanes()
        let split = try divider(tree).key.split
        workspace.setFractions(split: split, [0.3, 0.7])
        tree.apply(workspace.layout.root, animated: false)
        let divider = try self.divider(tree)
        let window = try XCTUnwrap(self.window)
        divider.mouseDown(with: mouse(.leftMouseDown, x: 304, clicks: 2, in: window))
        divider.mouseUp(with: mouse(.leftMouseUp, x: 304, clicks: 2, in: window))
        guard case .split(_, _, _, let even) = workspace.layout.root else { return XCTFail("a split") }
        XCTAssertEqual(even, [0.5, 0.5])
        tree.apply(workspace.layout.root, animated: false)
        divider.mouseDown(with: mouse(.leftMouseDown, x: 504, clicks: 2, in: window))
        guard case .split(_, _, _, let back) = workspace.layout.root else { return XCTFail("a split") }
        XCTAssertEqual(back[0], 0.3, accuracy: 1e-9)
    }

    func testAPaneThatClosesLeavesAndTheOtherTakesTheRoom() throws {
        let (workspace, tree) = try twoPanes()
        let closing = try XCTUnwrap(workspace.layout.panes.last)
        for tab in closing.tabs { workspace.close(tab.id) }
        tree.apply(workspace.layout.root, animated: false)
        XCTAssertEqual(frames(tree, workspace), [CGRect(x: 0, y: 0, width: 1008, height: 600)])
        XCTAssertNil(tree.panes[closing.id])
        XCTAssertTrue(tree.dividers.isEmpty)
    }

    func testTheDividerIsASplitterForVoiceOver() throws {
        let (_, tree) = try twoPanes()
        let divider = try divider(tree)
        XCTAssertEqual(divider.accessibilityRole(), .splitter)
        XCTAssertEqual(divider.accessibilityLabel(), "Split divider")
    }
}
