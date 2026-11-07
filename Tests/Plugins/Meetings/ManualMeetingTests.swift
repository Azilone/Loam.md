import Foundation
import PluginKit
import PluginKitTesting
import XCTest
@testable import MeetingsPlugin

final class ManualMeetingTests: XCTestCase {
    func testAnAgentWritesAMeetingWithEnglishProperties() async throws {
        let harness = try PluginTestHarness([MeetingsPlugin.self])
        let output = try await harness.run("meetings.new", [
            "title": "Team sync", "participants": "Ann, Bob", "date": "2026-10-30T09:15",
            "text": "## Decisions\n- Ship on the 10th",
        ])
        let path = try XCTUnwrap(try JSONDecoder().decode([String: String].self, from: Data(output.utf8))["path"])
        XCTAssertTrue(path.hasSuffix("/2026-10-30 0915 Team sync/\((path as NSString).lastPathComponent)"), path)
        let text = try harness.vault.read(path)
        XCTAssertTrue(text.hasPrefix("---\ndate: 2026-10-30T09:15\nparticipants: [Ann, Bob]\ntags: [meeting]\ntype: meeting\n---\n\n# "), text)
        XCTAssertTrue(text.hasSuffix("· Team sync\n\n## Decisions\n- Ship on the 10th\n"), text)
        do {
            _ = try await harness.run("meetings.new", ["title": "Bad", "date": "tomorrow"])
            XCTFail("a date that is not one is refused")
        } catch {}
    }
}
