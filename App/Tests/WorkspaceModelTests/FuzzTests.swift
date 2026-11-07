import PluginKitUI
import WorkspaceModel
import XCTest

/// Random operations from a fixed seed, checking every invariant after each one.
final class FuzzTests: XCTestCase {
    /// A tiny linear congruential generator: deterministic, so a failure replays the same way.
    private struct LCG {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    func testTwoThousandRandomOperationsKeepTheInvariants() throws {
        let resources: [Resource] = [
            .file("a.md"), .file("b.md"), .file("Dir/c.md"), .folder("Dir"), .virtual("calendar:2026-10"),
        ]
        let edges: [DropEdge] = [.leading, .trailing, .top, .bottom, .center]
        let placements: [Placement] = [.replace, .newTab, .beside]
        var rng = LCG(state: 42)
        var layout = makeLayout()
        var maxPanes = 1

        for step in 0..<2_000 {
            let panes = layout.panes
            let tabs = panes.flatMap(\.tabs)
            let pane = panes[rng.next(panes.count)].id
            let resource = resources[rng.next(resources.count)]
            let tab = tabs.isEmpty ? nil : tabs[rng.next(tabs.count)].id
            let operation = rng.next(8)
            switch operation {
            case 0, 1: layout.open(resource, placement: placements[rng.next(placements.count)])
            case 2: if let tab { layout.close(tab) }
            case 3: if let tab { layout.select(tab) }
            case 4: if let tab { layout.drop(tab: tab, on: pane, edge: edges[rng.next(edges.count)]) }
            case 5: layout.drop(resource: resource, on: pane, edge: edges[rng.next(edges.count)])
            case 6: if let tab { layout.moveTab(tab, to: pane, at: rng.next(5) - 1) }
            default:
                if case .split(let id, _, let children, _) = layout.root {
                    layout.setFractions(split: id, children.map { _ in Double(rng.next(9) + 1) })
                } else {
                    layout.focus(pane)
                }
            }
            maxPanes = max(maxPanes, layout.panes.count)
            do {
                try layout.validate()
            } catch {
                return XCTFail("step \(step), operation \(operation): \(error)")
            }
        }
        XCTAssertGreaterThan(maxPanes, 3, "the fuzz should reach nested layouts")
    }
}
