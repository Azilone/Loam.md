import BuiltinPlugins
import PluginKit
import PluginKitUI
import PluginKitUITesting
import TasksPlugin
import XCTest
@testable import HomeUI

@MainActor
final class HomeUITests: XCTestCase {
    private let logic = builtinPlugins.filter { ["tasks", "daily-notes", "note-graph"].contains($0.manifest.id) }

    private func harness(files: [String: String] = [:], logic: [Plugin.Type]? = nil) throws -> UIPluginHarness {
        try UIPluginHarness(logicPlugins: logic ?? self.logic, uiPlugins: [HomeUIPlugin.self], files: files)
    }

    private func model(_ harness: UIPluginHarness) throws -> HomeModel {
        try XCTUnwrap(harness.kernel.services.service(HomeUIPlugin.modelKey))
    }

    func testRegistersTheHomePageAndUnloadsCleanly() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("home-ui"), "\(harness.report)")
        for resource: Resource in [.home, .virtual("home:activity")] {
            XCTAssertEqual(harness.views.viewTypes(for: resource).map(\.id), ["home.page"], "\(resource)")
        }
        XCTAssertEqual(harness.views.viewTypes(for: .virtual("notes:")).map(\.id), [])
        XCTAssertNotNil(harness.kernel.commands.command(id: "home.open"))
        harness.host.deactivateAll()
        XCTAssertEqual(harness.views.all.map(\.id), [])
        XCTAssertNil(harness.kernel.commands.command(id: "home.open"))
    }

    func testStartsWithoutTheOptionalServices() throws {
        let harness = try harness(logic: [])
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("home-ui"), "\(harness.report)")
        let model = try model(harness)
        XCTAssertFalse(model.hasDailyNotes)
        XCTAssertNil(model.digest.tasks)
    }

    func testTheLayoutFollowsTheSettings() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertEqual(model.layout, .welcome)
        try harness.setSettings(.map(["layout": .string("activity"), "name": .string("Ada")]), for: "home-ui")
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertEqual(model.layout, .activity)
        XCTAssertTrue(model.greeting.hasSuffix(", Ada"))
        XCTAssertEqual(HomeUIPlugin.layout(of: .virtual("home:today")), .today)
        XCTAssertNil(HomeUIPlugin.layout(of: .home))
    }

    func testOpenCommandShowsTheAskedLayout() async throws {
        let harness = try harness()
        defer { harness.close() }
        _ = try await harness.run("home.open", ["layout": "overview"])
        XCTAssertEqual(harness.workspace.opened.last?.resource, .virtual("home:overview"))
    }

    func testButtonsRunOtherPluginsCommands() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.run(HomeModel.newNoteCommand)
        model.openToday(from: nil)
        XCTAssertEqual(harness.commands.ran, ["explorer.new-note", "daily.open-today"])
    }

    func testSummarisesNotesTasksAndToday() throws {
        let today = HomeDigest.day(Date(), .current)
        let harness = try harness(files: [
            "Projects/Plan.md": "# Plan\n\nA **bold** start.\n- [ ] Ship it 📅 \(today)\n- [x] Draft ✅ \(today)\n",
            "Daily/\(today).md": "# \(today)\n\n- Coffee\n- Call Ada\n",
        ])
        defer { harness.close() }
        let model = try model(harness)
        model.refresh()
        let digest = model.digest
        XCTAssertEqual(Set(digest.recent.map(\.path)), ["Projects/Plan.md", "Daily/\(today).md"])
        let plan = try XCTUnwrap(digest.recent.first { $0.path == "Projects/Plan.md" })
        XCTAssertEqual(plan.excerpt, "A bold start. · Ship it · Draft")
        XCTAssertEqual(digest.tasks?.today.map(\.text), ["Ship it"])
        XCTAssertEqual(digest.tasks?.doneToday.map(\.text), ["Draft"])
        XCTAssertEqual(digest.daily?.lines, ["Coffee", "Call Ada"])
        XCTAssertGreaterThan(digest.activity[today] ?? 0, 0)
        XCTAssertEqual(digest.streak, 1)
    }

    func testStreaksCountDaysInARow() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
        let activity = ["2026-10-21": 1, "2026-10-20": 2, "2026-10-19": 1, "2026-10-10": 1, "2026-10-11": 1,
                        "2026-10-12": 1, "2026-10-13": 1]
        let (current, best) = HomeDigest.streaks(activity, now: now, calendar: calendar)
        XCTAssertEqual(current, 3)
        XCTAssertEqual(best, 4)
        // Today still empty: the run up to yesterday counts.
        let (yesterday, _) = HomeDigest.streaks(["2026-10-20": 1, "2026-10-19": 1], now: now, calendar: calendar)
        XCTAssertEqual(yesterday, 2)
    }

    func testPlainTextDropsMarkdownMarks() {
        XCTAssertEqual(HomeDigest.plainText("## A [[Note|label]] and [link](x.md)"), "A label and link")
        XCTAssertEqual(HomeDigest.plainText("- [ ] Task ⏫ 📅 2026-10-22"), "Task")
        XCTAssertEqual(HomeDigest.plainText("1. `code` ~~gone~~"), "code gone")
    }
}
