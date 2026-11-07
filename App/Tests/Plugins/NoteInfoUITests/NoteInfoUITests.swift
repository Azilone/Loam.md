import BuiltinPlugins
import Foundation
@testable import NoteInfoUI
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest

/// The note inspector end to end, through the model its view drives, with the note graph, note query and tasks
/// logic plugins.
@MainActor
final class NoteInfoUITests: XCTestCase {
    private let files = [
        "Journal/2026-10-18.md": """
            ---
            created: 2026-10-18 07:58
            tags: [journal]
            mood: 4
            ---
            # Today

            Early start, coffee, reading. See the [plan](../Projects/Plan.md).

            - [x] Write the plan
            - [ ] Review the mockup #loam

            """,
        "Projects/Plan.md": "# Plan\n\nThe plan.\n",
        "Week.md": "# Week\n\nToday: [the day](Journal/2026-10-18.md).\n",
        "Lists/Reading.md": "# Reading list\n\n- [day](../Journal/2026-10-18.md)\n",
    ]

    private let day = "Journal/2026-10-18.md"

    private func harness(logic: Set<String> = ["note-graph", "note-query", "tasks"], editor: RecordingEditor? = nil) throws -> UIPluginHarness {
        try UIPluginHarness(
            logicPlugins: builtinPlugins.filter { logic.contains($0.manifest.id) },
            uiPlugins: [NoteInfoPlugin.self],
            files: files,
            editor: editor
        )
    }

    private func model(_ harness: UIPluginHarness) throws -> NoteInfoModel {
        try XCTUnwrap(harness.kernel.services.service(NoteInfoPlugin.modelKey), "\(harness.report)")
    }

    private func follow(_ harness: UIPluginHarness, _ path: String?) {
        harness.kernel.events.emit(ActiveResourceChanged(resource: path.map { .file($0) }))
    }

    func testListsTheBoardsShowingTheNote() throws {
        let harness = try UIPluginHarness(
            logicPlugins: builtinPlugins.filter { ["note-graph", "note-query", "canvas"].contains($0.manifest.id) },
            uiPlugins: [NoteInfoPlugin.self],
            files: files.merging(["Boards/Week.canvas": #"{"nodes":[{"id":"a","type":"file","file":"Journal/2026-10-18.md","x":0,"y":0,"width":400,"height":400}]}"#]) { $1 }
        )
        defer { harness.close() }
        follow(harness, day)
        let info = try XCTUnwrap(try model(harness).info)
        XCTAssertEqual(info.boards.map(\.path), ["Boards/Week.canvas"])
        XCTAssertEqual(info.boards.first?.title, "Week")
        XCTAssertTrue(try model(harness).report(for: nil).contains("Boards/Week.canvas"))
        follow(harness, "Projects/Plan.md")
        XCTAssertEqual(try model(harness).info?.boards, [])
    }

    func testTheStatsTabRendersWithAndWithoutANote() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("note-info"), "\(harness.report)")
        let note = Resource.file(day)
        let pages = harness.inspector.pages(for: note, viewType: nil)
        XCTAssertEqual(pages.map(\.page.title), ["Stats"])
        let sections = try XCTUnwrap(pages.first).sections
        XCTAssertEqual(sections.map(\.id), ["note-info.statistics"])
        XCTAssertTrue(harness.inspector.pages(for: .virtual("graph:"), viewType: nil).isEmpty)
        let size = CGSize(width: 300, height: 700)
        for section in sections {
            XCTAssertEqual(harness.render(section.makeView(note), size: size).frame.size, size, "no note open")
        }
        follow(harness, day)
        for section in sections {
            XCTAssertEqual(harness.render(section.makeView(note), size: size).frame.size, size, "with a note")
        }
    }

    func testShowsPropertiesTagsBacklinksLocationAndStatistics() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertNil(model.info)

        follow(harness, day)
        let info = try XCTUnwrap(model.info)
        XCTAssertEqual(info.title, "2026-10-18")
        XCTAssertEqual(info.folder, "Journal")
        XCTAssertEqual(info.properties.map(\.key), ["created", "mood"], "created first, tags left out")
        XCTAssertEqual(info.properties.map(\.value), ["2026-10-18 07:58", "4"])
        XCTAssertEqual(Set(info.tags), ["journal", "loam"])
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute) = (2026, 10, 18, 7, 58)
        XCTAssertEqual(info.created, Calendar.current.date(from: components), "from the property, not the file")
        XCTAssertNotNil(info.modified)
        XCTAssertEqual(info.backlinks.map(\.path), ["Lists/Reading.md", "Week.md"])
        XCTAssertEqual(info.backlinks.map(\.title), ["Reading", "Week"])
        XCTAssertEqual(info.statistics.tasksDone, 1)
        XCTAssertEqual(info.statistics.tasksTotal, 2)
        XCTAssertEqual(info.statistics.words, 15, "link destinations and checkboxes left out")
        XCTAssertEqual(info.statistics.readingMinutes, 1)
    }

    func testStatisticsCountWordsOfTheBodyOnly() {
        let stats = NoteInfoModel.statistics(of: "---\ntitle: Many words here\n---\n# Hi there\n\n- [ ] l'été, co-op 42\n")
        XCTAssertEqual(stats.words, 5, "Hi there l'été co-op 42: frontmatter and syntax left out")
        XCTAssertEqual(stats.characters, "# Hi there- [ ] l'été, co-op 42".count)
        XCTAssertEqual(NoteInfoModel.statistics(of: "").readingMinutes, 0)
        let long = NoteInfoModel.Statistics(words: 401)
        XCTAssertEqual(long.readingMinutes, 3)
    }

    func testFollowsUnsavedTextFromTheEditor() throws {
        let editor = RecordingEditor()
        let harness = try harness(editor: editor)
        defer { harness.close() }
        let model = try model(harness)
        follow(harness, "Projects/Plan.md")
        XCTAssertEqual(model.info?.statistics.words, 3)
        editor.texts["Projects/Plan.md"] = "# Plan\n\nThe plan, longer now.\n- [ ] one\n"
        harness.kernel.events.emit(DocumentTextChanged(path: "Projects/Plan.md"))
        XCTAssertEqual(model.info?.statistics.words, 6)
        XCTAssertEqual(model.info?.statistics.tasksTotal, 1, "tasks from the unsaved text too")
    }

    func testDisplaysTypedValues() {
        XCTAssertEqual(NoteInfoModel.display(.list([.string("a"), .number(2)])), "a, 2")
        XCTAssertEqual(NoteInfoModel.display(.number(2.5)), "2.5")
    }

    func testShowCommandReturnsJSON() async throws {
        let harness = try harness()
        defer { harness.close() }
        let none = try await harness.run("note-info.show")
        XCTAssertEqual(none, "No note is open.")

        struct Report: Decodable {
            let path: String
            let tags: [String]
            let backlinks: [String]
            let words: Int
            let tasksDone: Int?
            let tasksTotal: Int?
        }
        let json = try await harness.run("note-info.show", ["path": day])
        let report = try JSONDecoder().decode(Report.self, from: Data(json.utf8))
        XCTAssertEqual(report.path, day)
        XCTAssertEqual(report.backlinks, ["Lists/Reading.md", "Week.md"])
        XCTAssertEqual(report.tasksDone, 1)
        XCTAssertEqual(report.tasksTotal, 2)

        follow(harness, "Week.md")
        let active = try await harness.run("note-info.show")
        XCTAssertEqual(try JSONDecoder().decode(Report.self, from: Data(active.utf8)).path, "Week.md")
    }

    func testFollowsTheActiveNoteMovesAndChanges() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        follow(harness, "Projects/Plan.md")
        XCTAssertEqual(model.info?.backlinks.map(\.path), ["Journal/2026-10-18.md"])
        harness.kernel.events.emit(ActiveResourceChanged(resource: .file("image.png")))
        XCTAssertNil(model.info, "an image is no note")

        follow(harness, "Projects/Plan.md")
        try harness.kernel.refreshVault()
        try harness.vault.write("Week.md", "# Week\n\n[Plan](Projects/Plan.md)\n")
        try harness.kernel.refreshVault()
        XCTAssertEqual(model.info?.backlinks.map(\.path), ["Journal/2026-10-18.md", "Week.md"])

        let graph = try XCTUnwrap(harness.kernel.services.service(.noteGraph))
        _ = try graph.move(["Projects/Plan.md": "Archive/Plan.md"])
        XCTAssertEqual(model.active, "Archive/Plan.md")
        XCTAssertEqual(model.info?.folder, "Archive")
    }

    func testClickOpensInPlaceAndCommandClickBeside() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.open("Week.md", beside: false)
        model.open("Lists/Reading.md", beside: true)
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Week.md"), .file("Lists/Reading.md")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.replace, .beside])
    }

    func testWithoutTasksTheTaskRowIsHidden() throws {
        let harness = try harness(logic: ["note-graph", "note-query"])
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("note-info"), "\(harness.report)")
        let model = try model(harness)
        follow(harness, day)
        XCTAssertNil(model.info?.statistics.tasksTotal)
    }

    func testWithoutTheNoteGraphThePluginDoesNotStart() throws {
        let harness = try harness(logic: ["note-query"])
        defer { harness.close() }
        XCTAssertFalse(harness.host.isActive("note-info"))
        XCTAssertTrue(harness.inspector.all.isEmpty)
        XCTAssertNil(harness.kernel.commands.command(id: "note-info.show"))
    }
}
