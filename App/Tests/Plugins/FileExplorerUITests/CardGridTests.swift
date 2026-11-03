import AppKit
import BuiltinPlugins
@testable import FileExplorerUI
import Foundation
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest

/// The folder page's cards in AppKit (`CardGrid`): placed as a masonry, only the ones near the screen live, each
/// measured once per width, and each still its SwiftUI card (open, drag, menu).
@MainActor
final class CardGridTests: XCTestCase {
    private var window: NSWindow?
    private var harness: UIPluginHarness?

    override func tearDown() async throws {
        window?.close()
        window = nil
        harness?.close()
        harness = nil
        DragSession.shared.end()
        try await super.tearDown()
    }

    /// All Notes on 60 notes of different lengths, in a window 1000 by 700.
    private func grid() throws -> (ExplorerModel, CardGridView) {
        var files: [String: String] = [:]
        for index in 0..<60 {
            files[String(format: "Note %02d.md", index)] = String(repeating: "Line of text \(index)\n\n", count: 1 + index % 9)
        }
        let harness = try UIPluginHarness(
            logicPlugins: builtinPlugins.filter { $0.manifest.id == "files" },
            uiPlugins: [FileExplorerUIPlugin.self], files: files
        )
        self.harness = harness
        let model = try XCTUnwrap(harness.kernel.services.service(FileExplorerUIPlugin.modelKey))
        let grid = CardGridView(model: model)
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 1000, height: 700),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = grid
        window.orderFrontRegardless()
        self.window = window
        grid.update(CardGridView.State(
            resource: ExplorerModel.allNotes, items: model.cardItems(for: ExplorerModel.allNotes), isSettled: true,
            theme: .standard, chromeInset: 56
        ))
        grid.layoutSubtreeIfNeeded()
        return (model, grid)
    }

    func testTheCardsArePackedInColumnsWithoutOverlap() throws {
        let (model, grid) = try grid()
        let frames = grid.document.placedFrames
        XCTAssertEqual(frames.count, model.cardItems(for: ExplorerModel.allNotes).count)
        let columns = Dictionary(grouping: frames.values, by: \.minX)
        XCTAssertEqual(columns.count, FolderGridView.columnCount(for: 1000 - 2 * FolderGridView.horizontalPadding))
        for column in columns.values {
            let sorted = column.sorted { $0.minY < $1.minY }
            for (above, below) in zip(sorted, sorted.dropFirst()) {
                XCTAssertEqual(below.minY - above.maxY, FolderGridView.spacing, accuracy: 0.6, "cards stack with the gap")
            }
        }
        XCTAssertLessThan(grid.document.live.count, frames.count, "only the cards near the screen live")
        XCTAssertFalse(grid.document.live.isEmpty)
    }

    /// A card whose content wants more than its column (a row of tag pills, which are never cut) keeps its leading edge on
    /// the column's: it runs over to the right, as in a stack, instead of being centred on the column.
    func testACardWiderThanItsColumnKeepsItsLeadingEdge() throws {
        // A tag pill is never cut: one longer than the column makes the card's footer wider than the column.
        let tag = String(repeating: "longtag", count: 6)
        let files = ["A.md": "Short.\n", "Wide.md": "---\ntags: [\(tag)]\n---\nText.\n"]
        let harness = try UIPluginHarness(
            logicPlugins: builtinPlugins.filter { $0.manifest.id == "files" },
            uiPlugins: [FileExplorerUIPlugin.self], files: files
        )
        self.harness = harness
        let model = try XCTUnwrap(harness.kernel.services.service(FileExplorerUIPlugin.modelKey))
        let grid = CardGridView(model: model)
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 1000, height: 700),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = grid
        self.window = window
        grid.update(CardGridView.State(
            resource: ExplorerModel.allNotes, items: model.cardItems(for: ExplorerModel.allNotes), isSettled: true,
            theme: .standard, chromeInset: 56
        ))
        grid.layoutSubtreeIfNeeded()
        for (path, host) in grid.document.live {
            let column = try XCTUnwrap(grid.document.placedFrames[path])
            XCTAssertEqual(host.cardFrame, column, "\(path): the host is the column's")
            let root = host.controller.sizeThatFits(in: host.bounds.size)
            XCTAssertEqual(root.width, host.bounds.width, accuracy: 0.5, "\(path): the card's root keeps the column's width, so nothing centres it")
        }
    }

    func testAScrollMovesTheCardsWithoutMeasuringThemAgain() throws {
        let (_, grid) = try grid()
        let clip = grid.contentView
        let bottom = grid.document.frame.height - clip.bounds.height
        // Down by a screen at a time, each card measured as it comes near...
        var y = clip.bounds.minY
        while y < bottom {
            y = min(bottom, y + 300)
            clip.scroll(to: NSPoint(x: 0, y: y))
            grid.reflectScrolledClipView(clip)
        }
        let measured = grid.document.measureCount
        // ...and back up: nothing is measured again.
        while y > 0 {
            y = max(-56, y - 300)
            clip.scroll(to: NSPoint(x: 0, y: y))
            grid.reflectScrolledClipView(clip)
        }
        XCTAssertEqual(grid.document.measureCount, measured, "a scroll never measures a card it has measured")
        XCTAssertLessThanOrEqual(measured, grid.document.placedFrames.count + 2)
    }

    func testANarrowerPageMeasuresOnlyTheCardsNearTheScreen() throws {
        let (_, grid) = try grid()
        let before = grid.document.measureCount
        window?.setContentSize(NSSize(width: 800, height: 700))
        grid.layoutSubtreeIfNeeded()
        let measured = grid.document.measureCount - before
        XCTAssertGreaterThan(measured, 0)
        XCTAssertLessThan(measured, grid.document.placedFrames.count, "only the cards near the screen are laid out again")
    }

    /// The card at the top left, on screen.
    private func firstCard(_ grid: CardGridView) throws -> CardHost {
        let first = try XCTUnwrap(grid.document.placedFrames.min { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) })
        return try XCTUnwrap(grid.document.live[first.key])
    }

    func testACardKeepsItsMenu() throws {
        let (_, grid) = try grid()
        let host = try firstCard(grid)
        let point = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let target = try XCTUnwrap(window?.contentView?.hitTest(point))
        var view: NSView? = target
        var menu: NSMenu?
        while let current = view, menu == nil {
            menu = current.menu(for: event)
            view = current.superview
        }
        let titles = try XCTUnwrap(menu, "a right click on a card shows its menu").items.map(\.title)
        XCTAssertTrue(titles.contains("Open in New Tab"), "\(titles)")
    }

    /// A card the pointer went over is in its hover pose; the window resized under the still pointer moves it away,
    /// and once the resize ends it is made anew, out of that pose (its hosting view is never told the pointer left),
    /// at its place and its column's width. The one still under the pointer keeps its pose.
    func testACardThePointerLeftByAResizeIsNotLeftLifted() throws {
        let (_, grid) = try grid()
        let window = try XCTUnwrap(self.window)
        let host = try firstCard(grid)
        let path = try XCTUnwrap(host.path)
        var pointer: NSPoint? = NSPoint(x: host.cardFrame.midX, y: host.cardFrame.midY)
        grid.document.pointerLocation = { pointer }
        grid.document.showVisibleCards()
        XCTAssertTrue(host.mayBeHovered, "the pointer is over the card")
        let generation = host.controller.rootView.hoverGeneration

        // The page narrows and widens back under the still pointer.
        window.setContentSize(NSSize(width: 800, height: 700))
        grid.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 1000, height: 700))
        grid.layoutSubtreeIfNeeded()
        let stillUnder = grid.document.live.values.first { $0 !== host && $0.cardFrame.contains(NSPoint(x: 300, y: 300)) }
        stillUnder?.mayBeHovered = true
        pointer = NSPoint(x: 300, y: 300)
        let underGeneration = stillUnder?.controller.rootView.hoverGeneration
        grid.document.settleHover()

        let card = try XCTUnwrap(grid.document.live[path])
        XCTAssertGreaterThan(card.controller.rootView.hoverGeneration, generation, "the card the pointer left is out of its pose")
        XCTAssertFalse(card.mayBeHovered)
        if let stillUnder {
            XCTAssertEqual(stillUnder.controller.rootView.hoverGeneration, underGeneration, "the one under the pointer keeps it")
        }
        for (path, host) in grid.document.live {
            XCTAssertEqual(host.cardFrame, grid.document.placedFrames[path], "\(path) at its place, its column's width")
            XCTAssertTrue(CATransform3DIsIdentity(host.layer?.transform ?? CATransform3DIdentity), "\(path) not scaled")
        }
    }

    func testDraggingACardDragsItsNote() async throws {
        let (_, grid) = try grid()
        let window = try XCTUnwrap(self.window)
        let host = try firstCard(grid)
        let path = try XCTUnwrap(host.path)
        let point = host.convert(NSPoint(x: host.bounds.midX, y: CardDocumentView.outset + 30), to: nil)
        func mouse(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        // The drag's moves and release go in the queue first: a drag session reads them in its own loop.
        for step in 1...6 {
            NSApplication.shared.postEvent(mouse(.leftMouseDragged, NSPoint(x: point.x + CGFloat(step) * 10, y: point.y)), atStart: false)
        }
        NSApplication.shared.postEvent(mouse(.leftMouseUp, NSPoint(x: point.x + 60, y: point.y)), atStart: false)
        var dragged: DragPayload?
        window.sendEvent(mouse(.leftMouseDown, point))
        while let event = NSApplication.shared.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.2), inMode: .default, dequeue: true) {
            window.sendEvent(event)
            if dragged == nil { dragged = DragSession.shared.payload }
        }
        dragged = dragged ?? DragSession.shared.payload
        XCTAssertEqual(dragged, .resource(.file(path)), "the card's note is dragged")
    }
}
