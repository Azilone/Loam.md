import AppKit
import PluginKitUI
import SwiftUI
import WorkspaceModel
import XCTest
@testable import NotebookApp

/// Drag and drop through the controller, the API the drop delegates call once they decoded the payload.
@MainActor
final class WorkspaceDropTests: XCTestCase {
    private var workspace: WorkspaceController!
    private var activeChanges: [Resource?] = []

    override func setUp() async throws {
        workspace = WorkspaceController()
        activeChanges = []
        workspace.onActiveResourceChange = { [unowned self] in activeChanges.append($0) }
    }

    private var picture: [[String]] { workspace.layout.panes.map { $0.tabs.map(\.resource.path) } }

    private func tab(_ path: String) -> WorkspaceModel.Tab {
        workspace.layout.panes.flatMap(\.tabs).first { $0.resource.path == path }!
    }

    func testATabDroppedOnAnEdgeSplitsThePane() throws {
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .newTab)
        let a = tab("a.md")
        let context = workspace.context(for: a)
        let pane = workspace.layout.panes[0].id

        workspace.perform(.tab(a.id.raw), on: pane, edge: .trailing)

        XCTAssertEqual(picture, [["b.md"], ["a.md"]])
        guard case .split(_, .horizontal, _, _) = workspace.layout.root else { return XCTFail("expected a split") }
        XCTAssertEqual(workspace.activeResource, .file("a.md"))
        XCTAssertEqual(activeChanges.last, .file("a.md"))
        XCTAssertTrue(workspace.context(for: tab("a.md")) === context, "the tab keeps its view state when it moves")
        XCTAssertTrue(context.isActive)
        XCTAssertNoThrow(try workspace.layout.validate())
    }

    func testAResourceDroppedOnAPaneOpensATab() {
        workspace.open(.file("a.md"), placement: .replace)
        let pane = workspace.layout.panes[0].id

        workspace.perform(.resource(.file("n.md")), on: pane, edge: .center)
        XCTAssertEqual(picture, [["a.md", "n.md"]])
        XCTAssertEqual(workspace.activeResource, .file("n.md"))

        workspace.perform(.resource(.file("m.md")), on: pane, edge: .bottom)
        XCTAssertEqual(picture, [["a.md", "n.md"], ["m.md"]])
        guard case .split(_, .vertical, _, _) = workspace.layout.root else { return XCTFail("expected a split") }
        XCTAssertEqual(activeChanges, [.file("a.md"), .file("n.md"), .file("m.md")])
    }

    func testADropOfAClosedTabDoesNothing() {
        workspace.open(.file("a.md"), placement: .replace)
        let before = workspace.layout
        workspace.perform(.tab(UUID()), on: workspace.layout.panes[0].id, edge: .leading)
        XCTAssertEqual(workspace.layout, before)
    }

    func testDroppingOnATabBarReordersInTheGapUnderThePointer() {
        for path in ["a.md", "b.md", "c.md"] { workspace.open(.file(path), placement: .newTab) }
        let pane = workspace.layout.panes[0].id

        // a dropped in the gap between b and c (index 2 among a, b, c).
        workspace.perform(.tab(tab("a.md").id.raw), inTabBarOf: pane, at: 2)
        XCTAssertEqual(picture, [["b.md", "a.md", "c.md"]])
        // c dropped before the first tab.
        workspace.perform(.tab(tab("c.md").id.raw), inTabBarOf: pane, at: 0)
        XCTAssertEqual(picture, [["c.md", "b.md", "a.md"]])
        // c dropped on the empty area: appended.
        workspace.perform(.tab(tab("c.md").id.raw), inTabBarOf: pane, at: 3)
        XCTAssertEqual(picture, [["b.md", "a.md", "c.md"]])
        // In its own gap: nothing moves.
        let before = picture
        workspace.perform(.tab(tab("a.md").id.raw), inTabBarOf: pane, at: 1)
        workspace.perform(.tab(tab("a.md").id.raw), inTabBarOf: pane, at: 2)
        XCTAssertEqual(picture, before)
        XCTAssertEqual(workspace.activeResource, .file("a.md"))
    }

    func testDroppingOnAnotherTabBarMovesTheTabAndRemovesAnEmptiedPane() {
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .beside)
        workspace.open(.file("c.md"), placement: .newTab)
        XCTAssertEqual(picture, [["a.md"], ["b.md", "c.md"]])
        let right = workspace.layout.panes[1].id

        workspace.perform(.tab(tab("a.md").id.raw), inTabBarOf: right, at: 1)
        XCTAssertEqual(picture, [["b.md", "a.md", "c.md"]])
        XCTAssertEqual(workspace.layout.focusedPane, right)
        XCTAssertNoThrow(try workspace.layout.validate())
    }

    func testAResourceDroppedOnATabBarOpensAtThatPlace() {
        for path in ["a.md", "b.md"] { workspace.open(.file(path), placement: .newTab) }
        workspace.perform(.resource(.file("n.md")), inTabBarOf: workspace.layout.panes[0].id, at: 1)
        XCTAssertEqual(picture, [["a.md", "n.md", "b.md"]])
        XCTAssertEqual(workspace.activeResource, .file("n.md"))
    }
}

/// The drop highlight, rendered offscreen: the half of the pane on an edge, all of it on the center.
@MainActor
final class DropOverlayTests: XCTestCase {
    func testTheOverlayCoversTheHalfOfTheEdge() {
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(DropOverlay.rect(for: .leading, in: size), CGRect(x: 4, y: 4, width: 96, height: 92))
        XCTAssertEqual(DropOverlay.rect(for: .trailing, in: size), CGRect(x: 100, y: 4, width: 96, height: 92))
        XCTAssertEqual(DropOverlay.rect(for: .top, in: size), CGRect(x: 4, y: 4, width: 192, height: 46))
        XCTAssertEqual(DropOverlay.rect(for: .bottom, in: size), CGRect(x: 4, y: 50, width: 192, height: 46))
        XCTAssertEqual(DropOverlay.rect(for: .center, in: size), CGRect(x: 4, y: 4, width: 192, height: 92))
        XCTAssertEqual(DropOverlay.rect(for: .leading, in: .zero), .zero)
    }

    func testTheOverlayIsDrawnOnTheDropSide() throws {
        let leading = try render(.leading)
        XCTAssertTrue(isTinted(leading, x: 50, y: 50), "left half highlighted")
        XCTAssertFalse(isTinted(leading, x: 150, y: 50), "right half untouched")

        let bottom = try render(.bottom)
        XCTAssertTrue(isTinted(bottom, x: 100, y: 75))
        XCTAssertFalse(isTinted(bottom, x: 100, y: 25))

        let none = try render(nil)
        XCTAssertFalse(isTinted(none, x: 100, y: 50))
    }

    private func render(_ edge: DropEdge?) throws -> NSBitmapImageRep {
        let size = CGSize(width: 200, height: 100)
        let view = Color.white.overlay { DropOverlay(edge: edge) }.frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    /// Not plain white: the accent fill is there. `x`, `y` in points from the top left.
    private func isTinted(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        let scale = bitmap.pixelsWide / 200
        guard let color = bitmap.colorAt(x: x * scale, y: y * scale)?.usingColorSpace(.sRGB) else { return false }
        return color.redComponent < 0.97 || color.greenComponent < 0.97 || color.blueComponent < 0.97
    }

    /// A pane's tabs over its page with the drop target on it, highlighting the trailing half.
    func testAPaneRendersWithTheDropHighlight() throws {
        let workspace = WorkspaceController()
        workspace.open(.virtual("test:a"), placement: .replace)
        let pane = workspace.layout.panes[0]
        let size = CGSize(width: 400, height: 300)
        let view = VStack(spacing: 0) {
            TabStrip(pane: pane, isFocused: true, workspace: workspace, views: ViewRegistryStore(), frames: Measured([:]))
            Color.white.overlay { PaneDropZones(state: PaneDropState(edge: .trailing, isDragging: true)) }
        }
        .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let dir = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("pane-drop-trailing.png"))
        }
        let scale = bitmap.pixelsWide / Int(size.width)
        func tinted(_ x: Int, _ y: Int) -> Bool {
            guard let c = bitmap.colorAt(x: x * scale, y: y * scale)?.usingColorSpace(.sRGB) else { return false }
            return c.redComponent < 0.97 || c.greenComponent < 0.97 || c.blueComponent < 0.97
        }
        XCTAssertTrue(tinted(345, 170), "the trailing zone is lit")
        XCTAssertFalse(tinted(200, 170), "the middle of the page is not")
    }
}

/// The split zones of a drag: "Add left split" and "Add right split", and the same above and below.
@MainActor
final class SplitZonesTests: XCTestCase {
    private let size = CGSize(width: 800, height: 500)
    private let sides: [DropEdge] = [.leading, .trailing, .top, .bottom]

    func testFourZonesFillTheRingAroundTheMiddle() {
        let zones = SplitZoneLayout.zones(in: size)
        XCTAssertEqual(Set(zones.keys), Set(sides))
        let left = zones[.leading]!, right = zones[.trailing]!, top = zones[.top]!, bottom = zones[.bottom]!
        XCTAssertEqual(left.width, right.width, accuracy: 0.001)
        XCTAssertEqual(top.height, bottom.height, accuracy: 0.001)
        XCTAssertEqual(left.minX, size.width - right.maxX, accuracy: 0.001, "mirrored")
        XCTAssertEqual(top.minY, size.height - bottom.maxY, accuracy: 0.001, "mirrored")
        XCTAssertLessThanOrEqual(left.maxY, bottom.minY)
        XCTAssertGreaterThanOrEqual(left.minY, top.maxY)
        XCTAssertEqual(SplitZoneLayout.zones(in: .zero), [:])
    }

    /// The point of the layout: whatever the size, and whichever zone is lit and wherever the pointer is, no zone touches
    /// another or leaves the pane, and the middle where a tab is dropped stays.
    func testNoZoneEverOverlapsAnotherOrLeavesThePane() {
        let sizes: [CGSize] = [
            CGSize(width: 800, height: 500), CGSize(width: 1400, height: 900), CGSize(width: 300, height: 400),
            CGSize(width: 400, height: 1200), CGSize(width: 260, height: 180), CGSize(width: 200, height: 150),
            CGSize(width: 120, height: 80), CGSize(width: 600, height: 120), CGSize(width: 90, height: 700),
        ]
        let pane = { (size: CGSize) in CGRect(origin: .zero, size: size) }
        for size in sizes {
            for active in [nil] + sides.map({ Optional($0) }) {
                for pointer in [CGPoint(x: 0, y: 0), CGPoint(x: size.width / 2, y: size.height / 2), CGPoint(x: size.width, y: size.height)] {
                    let zones = SplitZoneLayout.zones(in: size, active: active, pointer: pointer)
                    let context = "\(size) active \(String(describing: active)) pointer \(pointer)"
                    for (edge, rect) in zones {
                        XCTAssertTrue(pane(size).contains(rect), "\(edge) leaves the pane: \(context)")
                        XCTAssertGreaterThan(rect.width, 0, "\(edge) \(context)")
                        XCTAssertGreaterThan(rect.height, 0, "\(edge) \(context)")
                    }
                    let all = Array(zones)
                    for (i, one) in all.enumerated() {
                        for other in all[(i + 1)...] {
                            XCTAssertFalse(one.value.intersects(other.value), "\(one.key) meets \(other.key): \(context)")
                        }
                    }
                    // The middle: what the zones leave between them, at least the minimum.
                    if zones.count == 4 {
                        let middle = CGRect(
                            x: zones[.leading]!.maxX, y: zones[.top]!.maxY,
                            width: zones[.trailing]!.minX - zones[.leading]!.maxX,
                            height: zones[.bottom]!.minY - zones[.top]!.maxY
                        )
                        XCTAssertGreaterThanOrEqual(middle.width, SplitZoneLayout.minimumMiddle.width, context)
                        XCTAssertGreaterThanOrEqual(middle.height, SplitZoneLayout.minimumMiddle.height, context)
                    }
                }
            }
        }
    }

    func testASmallPaneKeepsOnlyThePairsThatLeaveARoomyMiddle() {
        XCTAssertEqual(Set(SplitZoneLayout.zones(in: CGSize(width: 600, height: 120)).keys), [.leading, .trailing], "too short for strips")
        XCTAssertEqual(Set(SplitZoneLayout.zones(in: CGSize(width: 90, height: 700)).keys), [.top, .bottom], "too narrow for sides")
        XCTAssertEqual(SplitZoneLayout.zones(in: CGSize(width: 90, height: 90)), [:], "nothing fits: a tab only")
    }

    func testTheLitZoneGrowsTowardsThePointerAndTheOthersMakeWay() {
        let idle = SplitZoneLayout.zones(in: size)
        let lit = SplitZoneLayout.zones(in: size, active: .leading, pointer: CGPoint(x: 260, y: 250))
        XCTAssertGreaterThan(lit[.leading]!.width, idle[.leading]!.width)
        XCTAssertEqual(lit[.leading]!.minX, idle[.leading]!.minX, accuracy: 0.001, "grows inward only")
        XCTAssertEqual(lit[.top], idle[.top], "the strips are not in its way")
        let band = SplitZoneLayout.zones(in: size, active: .top, pointer: CGPoint(x: 400, y: 150))
        XCTAssertGreaterThan(band[.top]!.height, idle[.top]!.height)
        XCTAssertGreaterThan(band[.leading]!.minY, idle[.leading]!.minY, "the sides start lower")
        XCTAssertLessThan(band[.leading]!.height, idle[.leading]!.height)
        // A pointer that has not reached the zone's border does not grow it.
        let near = SplitZoneLayout.zones(in: size, active: .leading, pointer: CGPoint(x: 5, y: 250))
        XCTAssertEqual(near[.leading]!.width, idle[.leading]!.width, accuracy: 0.001)
    }

    func testTheEdgeIsTheZoneUnderThePointer() {
        let zones = SplitZoneLayout.zones(in: size)
        for side in sides {
            let rect = zones[side]!
            XCTAssertEqual(SplitZoneLayout.edge(at: CGPoint(x: rect.midX, y: rect.midY), in: size, current: nil), side)
        }
        XCTAssertEqual(SplitZoneLayout.edge(at: CGPoint(x: 400, y: 250), in: size, current: nil), .center)
        // The corners go to the strips, and a pointer in the gap to the zone it is nearest.
        XCTAssertEqual(SplitZoneLayout.edge(at: CGPoint(x: 12, y: 12), in: size, current: nil), .top)
        let gap = CGPoint(x: zones[.leading]!.maxX + 3, y: 250)
        XCTAssertEqual(SplitZoneLayout.edge(at: gap, in: size, current: nil), .leading)
        // In a pane with no zones the drop is a tab.
        XCTAssertEqual(SplitZoneLayout.edge(at: CGPoint(x: 10, y: 10), in: CGSize(width: 90, height: 90), current: nil), .center)
    }

    func testOnlyTheZoneNearThePointerShows() {
        let zones = SplitZoneLayout.zones(in: size)
        XCTAssertEqual(sides.map { SplitZoneLayout.presence(of: $0, in: zones, pointer: nil) }, [0, 0, 0, 0])
        // In the middle of the page, far from every zone: none.
        XCTAssertEqual(sides.map { SplitZoneLayout.presence(of: $0, in: zones, pointer: CGPoint(x: 400, y: 250)) }, [0, 0, 0, 0])
        // Nearing the left zone: it alone, more of it closer.
        let leading = zones[.leading]!
        let far = SplitZoneLayout.presence(of: .leading, in: zones, pointer: CGPoint(x: leading.maxX + 80, y: 250))
        let close = SplitZoneLayout.presence(of: .leading, in: zones, pointer: CGPoint(x: leading.maxX + 20, y: 250))
        XCTAssertGreaterThan(far, 0)
        XCTAssertGreaterThan(close, far)
        XCTAssertEqual(SplitZoneLayout.presence(of: .top, in: zones, pointer: CGPoint(x: leading.maxX + 20, y: 250)), 0)
        // It leans towards the pointer.
        let lean = SplitZoneLayout.lean(of: .leading, rect: leading, pointer: CGPoint(x: leading.maxX + 20, y: 250), presence: close)
        XCTAssertGreaterThan(lean.width, 0)
    }

    func testTheZonesAreDrawnAndTheLitOneIsGreen() throws {
        let idle = try render(edge: nil, pointer: nil)
        let zones = SplitZoneLayout.zones(in: size)
        for side in sides {
            let rect = zones[side]!
            XCTAssertFalse(isTinted(idle, x: Int(rect.minX) + 8, y: Int(rect.midY)), "\(side) waits for the pointer")
        }
        XCTAssertFalse(isTinted(idle, x: 400, y: 250), "the middle of the page is clear")
        let leading = zones[.leading]!
        let nearing = try render(edge: nil, pointer: CGPoint(x: leading.maxX + 15, y: 250))
        XCTAssertTrue(isTinted(nearing, x: Int(leading.midX), y: Int(leading.midY)), "the zone the pointer nears comes in")
        XCTAssertFalse(isTinted(nearing, x: Int(zones[.trailing]!.midX), y: Int(zones[.trailing]!.midY)), "the others do not")

        let near = try render(edge: .top, pointer: CGPoint(x: 400, y: 60))
        let top = SplitZoneLayout.zones(in: size, active: .top, pointer: CGPoint(x: 400, y: 60))[.top]!
        XCTAssertTrue(isGreen(near, x: Int(top.midX), y: Int(top.maxY) - 8), "the lit zone is green")
        XCTAssertFalse(isGreen(near, x: 60, y: 250), "the others are not")

        // For a look at the dark page and at small panes, with LOAM_SNAPSHOT_DIR.
        _ = try render(edge: nil, pointer: nil, dark: true)
        _ = try render(edge: .trailing, pointer: CGPoint(x: 600, y: 200), dark: true)
        _ = try render(edge: .leading, pointer: CGPoint(x: 120, y: 120), dark: false, size: CGSize(width: 300, height: 220), name: "small")
        _ = try render(edge: nil, pointer: nil, dark: false, size: CGSize(width: 520, height: 130), name: "short")
    }

    private func render(
        edge: DropEdge?, pointer: CGPoint?, dark: Bool = false, size: CGSize? = nil, name: String? = nil
    ) throws -> NSBitmapImageRep {
        let size = size ?? self.size
        let view = (dark ? Color(white: 0.14) : Color.white)
            .overlay { SplitZones(edge: edge, pointer: pointer, isDragging: true) }
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let dir = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] {
            let file = "split-zones-\(name ?? (edge == nil ? "idle" : "near"))\(dark ? "-dark" : "").png"
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
        }
        return bitmap
    }

    private func color(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        let scale = bitmap.pixelsWide / Int(size.width)
        return bitmap.colorAt(x: x * scale, y: y * scale)?.usingColorSpace(.sRGB)
    }

    private func isTinted(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        guard let c = color(bitmap, x: x, y: y) else { return false }
        return c.redComponent < 0.99 || c.greenComponent < 0.99 || c.blueComponent < 0.99
    }

    private func isGreen(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        guard let c = color(bitmap, x: x, y: y) else { return false }
        return c.greenComponent > c.redComponent + 0.02 && c.greenComponent > c.blueComponent + 0.02
    }
}
