import PluginKitUI
import XCTest

@MainActor
final class ViewContextTests: XCTestCase {
    private struct Caret: Codable, Equatable {
        var line: Int
    }

    func testStateRoundTripsAndReachesTheShell() throws {
        let context = ViewContext(resource: .file("a.md"))
        var saved: [Data?] = []
        context.onStateChange = { saved.append($0) }
        XCTAssertNil(context.state(Caret.self))

        context.setState(Caret(line: 12))
        XCTAssertEqual(context.state(Caret.self), Caret(line: 12))
        XCTAssertEqual(saved.count, 1)

        let restored = ViewContext(resource: .file("a.md"), state: saved[0])
        XCTAssertEqual(restored.state(Caret.self), Caret(line: 12))
    }

    func testStateOfAnotherShapeIsIgnored() {
        let context = ViewContext(resource: .file("a.md"), state: Data("[1, 2]".utf8))
        XCTAssertNil(context.state(Caret.self))
    }
}
