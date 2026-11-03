import Foundation
import WorkspaceModel
import XCTest

/// Hands out 1, 2, 3, ... as UUIDs so layouts, and failures, are the same on every run.
final class CountingIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0

    func make() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        next += 1
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", next))!
    }
}

func makeLayout() -> WorkspaceLayout {
    let ids = CountingIDs()
    return WorkspaceLayout(makeID: { ids.make() })
}

extension WorkspaceLayout {
    /// The resource paths of each pane in reading order, a compact picture of the layout for assertions.
    var picture: [[String]] { panes.map { $0.tabs.map(\.resource.path) } }

    var rootSplit: (id: UUID, axis: SplitAxis, children: [LayoutNode], fractions: [Double])? {
        guard case .split(let id, let axis, let children, let fractions) = root else { return nil }
        return (id, axis, children, fractions)
    }

    func selectedPath(_ pane: Pane) -> String? { pane.tabs.first { $0.id == pane.selected }?.resource.path }
}

func assertValid(_ layout: WorkspaceLayout, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNoThrow(try layout.validate(), file: file, line: line)
}

func assertFractions(_ actual: [Double]?, _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
    guard let actual, actual.count == expected.count else {
        return XCTFail("fractions \(String(describing: actual)) != \(expected)", file: file, line: line)
    }
    for (a, e) in zip(actual, expected) { XCTAssertEqual(a, e, accuracy: 1e-9, file: file, line: line) }
}
