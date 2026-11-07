import MeetingsPlugin
import PluginKit
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import MeetingsUI

/// The recorder's place in the app: its status bar item, commands, menus and messages. Recording itself needs the
/// microphone, so it is tried in the real app (`ui-verify`).
@MainActor
final class MeetingsUITests: XCTestCase {
    func testTheRecorderAddsItsItemCommandsAndMenus() async throws {
        let harness = try UIPluginHarness(logicPlugins: [MeetingsPlugin.self], uiPlugins: [MeetingsUIPlugin.self], files: [
            "Meetings/2026-10-22 1430 Point/Notes.md": "# Point\n",
            "Dictaphone/memo.m4a": "",
        ])
        defer { harness.close() }
        XCTAssertEqual(harness.panels.links.map(\.id), ["meetings.link"])
        XCTAssertTrue(harness.panels.panels(in: .statusBar).isEmpty)
        // The engine reports from its background work: a handler must not assume the main actor (the crash on Stop).
        nonisolated(unsafe) let events = harness.kernel.events
        await Task.detached { events.emit(MeetingFailed(folder: "x", title: "x", message: "x")) }.value
        for id in ["meetings.start", "meetings.stop", "meetings.mark", "meetings.import-file", "meetings.setup", "meetings.voice-note"] {
            XCTAssertNotNil(harness.kernel.commands.command(id: id), id)
        }
        let memo = harness.resourceActions.actions(for: .file("Dictaphone/memo.m4a")).map(\.id)
        XCTAssertEqual(memo, ["meetings.from-audio"])
        // Only a folder with recording data can be processed again.
        XCTAssertEqual(harness.resourceActions.actions(for: .folder("Meetings/2026-10-22 1430 Point")).map(\.id), [])
        try harness.vault.writeData("Meetings/2026-10-22 1430 Point/.raw/meeting.json", Data("{}".utf8))
        XCTAssertEqual(harness.resourceActions.actions(for: .folder("Meetings/2026-10-22 1430 Point")).map(\.id), ["meetings.reprocess"])

        // Stopping with nothing recorded says so.
        let answer = try await harness.run("meetings.stop")
        XCTAssertEqual(answer, "Nothing is being recorded.")

        // Starting offers the three kinds of recording.
        _ = try await harness.run("meetings.start")
        XCTAssertEqual(harness.quickPick.items?("").count, 3)

        harness.host.deactivateAll()
        XCTAssertTrue(harness.panels.links.isEmpty)
    }

    func testMessagesFollowTheEngine() async throws {
        let harness = try UIPluginHarness(logicPlugins: [MeetingsPlugin.self], uiPlugins: [MeetingsUIPlugin.self])
        defer { harness.close() }
        harness.kernel.events.emit(MeetingProgress(folder: "M/a", title: "Point", step: "Summary…"))
        try await Task.sleep(nanoseconds: 50_000_000)
        harness.kernel.events.emit(MeetingFinished(folder: "M/a", title: "Point", note: "M/a/Summary.md", cost: 0.04, background: false))
        harness.kernel.events.emit(MeetingFailed(folder: "M/b", title: "Other", message: "OpenRouter 401"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("M/a/Summary.md")])
        XCTAssertEqual(harness.toasts.messages.map(\.isError), [false, true])
        XCTAssertTrue(harness.toasts.messages[0].text.hasSuffix("Point · $0.04"), harness.toasts.messages[0].text)
    }

    func testTheNotesTimestampsFollowTheLinesAsTheyAreTyped() throws {
        let harness = try UIPluginHarness(logicPlugins: [MeetingsPlugin.self], uiPlugins: [MeetingsUIPlugin.self])
        defer { harness.close() }
        let meetings = try XCTUnwrap(harness.kernel.services.service(.meetings))
        let session = try meetings.start(kind: .meeting, mode: .room)
        let times = RecorderNotes()
        times.changed("# Meeting\n\nBud", at: 5)
        times.changed("# Meeting\n\nBudget approved", at: 9)
        times.changed("# Meeting\n\nBudget approved\nDemo", at: 30)
        XCTAssertEqual(times.starts, ["# Meeting": 5, "Budget approved": 5, "Demo": 30])
        session.setNoteTimes(times.starts)
        XCTAssertEqual(session.state.noteTimes["Demo"], 30)
    }
}

/// The recorder's windows drawn offscreen (LOAM_SNAPSHOT_DIR keeps the PNGs).
@MainActor
final class MeetingsSnapshotTests: XCTestCase {
    private func snapshot(_ view: some View, name: String) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 20, name)
        if let dir = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testTheWindowsDraw() throws {
        var settings = MeetingsSettings()
        settings.summaryLanguage = "French"
        let setup = SetupModel(settings: settings) { _ in }
        try snapshot(SetupView(model: setup) {}.frame(width: 400).background(Color(nsColor: .windowBackgroundColor)), name: "meetings-setup")
        let form = SpeakerNamesForm(people: [Person(name: "Paul", labels: ["system0:1"], evidence: "« thanks Paul »"), Person(name: "", labels: ["system0:0"])],
                                    utterances: [])
        try snapshot(SpeakerNamesView(form: form) {}.frame(width: 420).background(Color(nsColor: .windowBackgroundColor)), name: "meetings-speakers")
        let harness = try UIPluginHarness(logicPlugins: [MeetingsPlugin.self], uiPlugins: [ContextGrabber.self])
        defer { harness.close() }
        let model = RecorderModel(meetings: try XCTUnwrap(harness.kernel.services.service(.meetings)), context: try XCTUnwrap(ContextGrabber.context))
        try snapshot(OverlayPill(model: model).background(Color.gray), name: "meetings-pill")
    }
}

/// Hands a test the plugin context the host gives it.
final class ContextGrabber: UIPlugin {
    static let manifest = PluginManifest(id: "test.grabber", name: "Grabber", version: "0.1.0")
    @MainActor static weak var context: PluginContext?
    init() {}
    @MainActor func activateUI(context: PluginContext) throws { Self.context = context }
}

@MainActor
final class MeetingsPageTests: XCTestCase {
    func testTheSidebarLinkOpensThePageOfRecordings() async throws {
        let harness = try UIPluginHarness(logicPlugins: [MeetingsPlugin.self], uiPlugins: [MeetingsUIPlugin.self])
        defer { harness.close() }
        XCTAssertTrue(harness.panels.links.contains { $0.id == "meetings.link" && $0.resource == MeetingsUIPlugin.pageResource })
        XCTAssertEqual(harness.views.viewTypes(for: MeetingsUIPlugin.pageResource).map(\.id), ["meetings.page"])
        _ = try await harness.run("meetings.open")
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [MeetingsUIPlugin.pageResource])
        let meetings = try XCTUnwrap(harness.kernel.services.service(.meetings))
        let session = try meetings.start(kind: .meeting, mode: .room, title: "Point")
        XCTAssertEqual(meetings.recordings().map(\.title), ["Point"])
        XCTAssertEqual(meetings.note(of: session.state), session.state.folder + "/Point.md")
    }

    func testTheHistorySaysWhenInWords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z")!
        func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
        XCTAssertEqual(HistoryLabels.when(at("2026-10-23T07:30:00Z"), now: now, calendar: calendar), "Today 09:30")
        XCTAssertEqual(HistoryLabels.when(at("2026-10-22T16:05:00Z"), now: now, calendar: calendar), "Yesterday 18:05")
        XCTAssertEqual(HistoryLabels.when(at("2026-10-21T16:05:00Z"), now: now, calendar: calendar), "Oct 21 18:05")
        XCTAssertTrue(HistoryLabels.when(at("2025-12-30T16:05:00Z"), now: now, calendar: calendar).contains("2025"))
        XCTAssertTrue(HistoryLabels.when(at("2026-10-22T16:05:00Z"), now: now, calendar: calendar).hasPrefix("Yesterday"))
        XCTAssertEqual(Set(MeetingOrigin.allCases.map { HistoryLabels.origin($0) }).count, MeetingOrigin.allCases.count)
    }
}
