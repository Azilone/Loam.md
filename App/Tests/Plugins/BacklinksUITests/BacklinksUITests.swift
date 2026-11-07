@testable import BacklinksUI
import BuiltinPlugins
import Foundation
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest

/// The Backlinks panel end to end, through the model its view drives, with the `note-graph` logic plugin.
@MainActor
final class BacklinksUITests: XCTestCase {
    private let files = [
        "Projects/Plan.md": "# Plan\n\nThe plan.\n",
        "Welcome.md": """
            ---
            tags: [start]
            ---
            # Welcome

            Start with the [plan](Projects/Plan.md) today.
            Nothing here.
            Again: [Plan](<Projects/Plan.md#goals> "goals") and [web](https://example.com).
            Third [plan](Projects/Plan.md).

            """,
        "Ideas/Spark.md": "# Spark\n\n  See [the plan](../Projects/Plan.md).  \n",
        "Journal.md": "# Journal\n\nWorked on the Plan all day.\nplanning is not a mention.\n",
        "Other.md": "# Other\n\nAn airplane, a [link](Journal.md).\n",
    ]

    private func harness(files: [String: String]? = nil) throws -> UIPluginHarness {
        try UIPluginHarness(
            logicPlugins: builtinPlugins.filter { $0.manifest.id == "note-graph" },
            uiPlugins: [BacklinksPlugin.self],
            files: files ?? self.files
        )
    }

    private func model(_ harness: UIPluginHarness) throws -> BacklinksModel {
        try XCTUnwrap(harness.kernel.services.service(BacklinksPlugin.modelKey), "\(harness.report)")
    }

    private func follow(_ harness: UIPluginHarness, _ path: String?) {
        harness.kernel.events.emit(ActiveResourceChanged(resource: path.map { .file($0) }))
    }

    func testListsTheBoardsShowingTheNote() throws {
        let harness = try UIPluginHarness(
            logicPlugins: builtinPlugins.filter { ["note-graph", "canvas"].contains($0.manifest.id) },
            uiPlugins: [BacklinksPlugin.self],
            files: files.merging(["Boards/Plans.canvas": #"{"nodes":[{"id":"a","type":"file","file":"Projects/Plan.md","x":0,"y":0,"width":400,"height":400}]}"#]) { $1 }
        )
        defer { harness.close() }
        follow(harness, "Projects/Plan.md")
        XCTAssertEqual(try model(harness).boards.map(\.path), ["Boards/Plans.canvas"])
        XCTAssertEqual(try model(harness).boards.first?.title, "Plans")
    }

    func testSectionsMakeTheLinksTabAndRender() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("backlinks"), "\(harness.report)")
        let note = Resource.file("Projects/Plan.md")
        // A "Links" tab of its own; "On boards" and the mentions only while there are some.
        let pages = harness.inspector.pages(for: note, viewType: nil)
        XCTAssertEqual(pages.map(\.page.title), ["Links"])
        XCTAssertEqual(pages.first?.sections.map(\.id), ["backlinks.linked"])
        XCTAssertTrue(harness.inspector.sections(for: note, viewType: nil, in: .info).isEmpty)
        let size = CGSize(width: 280, height: 500)
        for section in pages.flatMap(\.sections) {
            XCTAssertEqual(harness.render(section.makeView(note), size: size).frame.size, size, "no note open")
        }
        follow(harness, "Projects/Plan.md")
        for section in harness.inspector.pages(for: note, viewType: nil).flatMap(\.sections) {
            XCTAssertEqual(harness.render(section.makeView(note), size: size).frame.size, size, "with backlinks")
        }
    }

    func testListsBacklinksWithTheirContextLines() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertNil(model.active)
        XCTAssertEqual(model.backlinks, [])

        follow(harness, "Projects/Plan.md")
        XCTAssertEqual(model.active, "Projects/Plan.md")
        XCTAssertEqual(model.activeTitle, "Plan")
        XCTAssertEqual(model.backlinks.map(\.path), ["Ideas/Spark.md", "Welcome.md"])
        XCTAssertEqual(model.backlinks.map(\.title), ["Spark", "Welcome"])
        XCTAssertEqual(model.backlinks.map(\.folder), ["Ideas", ""])

        let spark = model.backlinks[0]
        XCTAssertEqual(spark.lines.map(\.text), ["See the plan."], "trimmed, the link shown as its text")
        XCTAssertEqual(spark.lines[0].fragments, [
            .init(text: "See ", isMatch: false), .init(text: "the plan", isMatch: true), .init(text: ".", isMatch: false),
        ])

        let welcome = model.backlinks[1]
        XCTAssertEqual(welcome.lines.map(\.text), ["Start with the plan today.", "Again: Plan and web."], "two at most")
        XCTAssertEqual(welcome.lines.map(\.id), [5, 7], "line numbers in the file, frontmatter included")
        XCTAssertEqual(welcome.lines[1].fragments.filter(\.isMatch).map(\.text), ["Plan"], "only the link to the note")

        await model.settled()
        // Ids are unique across both sections: SwiftUI draws duplicate ids as empty rows.
        let ids = (model.backlinks + model.mentions).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testUnlinkedMentionsSkipLinkingNotesAndPartialWords() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        follow(harness, "Projects/Plan.md")
        await model.settled()
        XCTAssertEqual(model.mentions.map(\.path), ["Journal.md"], "Welcome and Spark link; airplane is no mention")
        XCTAssertEqual(model.mentions[0].lines.map(\.text), ["Worked on the Plan all day."])
        XCTAssertEqual(model.mentions[0].lines[0].fragments.filter(\.isMatch).map(\.text), ["Plan"])
        XCTAssertTrue(model.mentions.allSatisfy { $0.kind == .mention })
    }

    func testMentionsAreCappedAndShortTitlesIgnored() {
        let candidates = (0..<30).map { "N\($0).md" }
        let found = BacklinksModel.unlinkedMentions(
            of: "Plan", target: "Plan.md", candidates: candidates + ["Plan.md"], excluding: ["N0.md"],
            read: { _ in "a plan" }
        )
        XCTAssertEqual(found.count, BacklinksModel.maxMentions)
        XCTAssertEqual(found.first?.path, "N1.md")
        XCTAssertFalse(found.contains { $0.path == "Plan.md" })
        XCTAssertTrue(BacklinksModel.unlinkedMentions(
            of: "AI", target: "AI.md", candidates: ["A.md"], excluding: [], read: { _ in "about AI" }
        ).isEmpty)
    }

    func testMentionsCommandReturnsJSONForAPathOrTheOpenNote() async throws {
        let harness = try harness()
        defer { harness.close() }
        let none = try await harness.run("backlinks.mentions")
        XCTAssertEqual(none, "No note is open.")

        let json = try await harness.run("backlinks.mentions", ["path": "Projects/Plan.md"])
        struct Mention: Decodable, Equatable { let path: String; let title: String; let lines: [String] }
        let mentions = try JSONDecoder().decode([Mention].self, from: Data(json.utf8))
        XCTAssertEqual(mentions, [Mention(path: "Journal.md", title: "Journal", lines: ["Worked on the Plan all day."])])

        follow(harness, "Journal.md")
        let forActive = try await harness.run("backlinks.mentions")
        XCTAssertEqual(try JSONDecoder().decode([Mention].self, from: Data(forActive.utf8)), [], "Other links to it")
    }

    func testFollowsTheActiveResourceAndTheWorkspaceAtActivation() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        follow(harness, "Journal.md")
        XCTAssertEqual(model.backlinks.map(\.path), ["Other.md"])
        follow(harness, "Welcome.md")
        XCTAssertEqual(model.backlinks, [])
        harness.kernel.events.emit(ActiveResourceChanged(resource: .virtual("calendar:2026-10")))
        XCTAssertNil(model.active, "a virtual page is no note")
        harness.kernel.events.emit(ActiveResourceChanged(resource: .file("image.png")))
        XCTAssertNil(model.active)

        // Restarted while a note is focused, the plugin starts on it.
        harness.workspace.activeResource = .file("Projects/Plan.md")
        _ = harness.host.deactivate("backlinks")
        _ = harness.host.apply(enabled: nil)
        XCTAssertTrue(harness.host.isActive("backlinks"), "\(harness.report)")
        let restarted = try self.model(harness)
        XCTAssertEqual(restarted.active, "Projects/Plan.md")
        XCTAssertEqual(restarted.backlinks.count, 2)
    }

    func testRefreshesWhenANoteChangesOrMoves() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        follow(harness, "Projects/Plan.md")
        try harness.kernel.refreshVault()

        try harness.vault.write("Journal.md", "# Journal\n\nNow linked: [Plan](Projects/Plan.md).\n")
        try harness.kernel.refreshVault()
        XCTAssertEqual(model.backlinks.map(\.path), ["Ideas/Spark.md", "Journal.md", "Welcome.md"])
        XCTAssertEqual(model.backlinks[1].lines.map(\.text), ["Now linked: Plan."])
        await model.settled()
        XCTAssertEqual(model.mentions, [], "a linking note is no unlinked mention")

        let graph = try XCTUnwrap(harness.kernel.services.service(.noteGraph))
        _ = try graph.move(["Projects/Plan.md": "Archive/Plan.md"])
        XCTAssertEqual(model.active, "Archive/Plan.md", "follows its note")
        XCTAssertEqual(model.backlinks.count, 3)
        XCTAssertEqual(model.backlinks[0].lines.map(\.text), ["See the plan."], "links rewritten, still found")
    }

    func testClickOpensInPlaceAndCommandClickBeside() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.open("Welcome.md", beside: false)
        model.open("Ideas/Spark.md", beside: true)
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Welcome.md"), .file("Ideas/Spark.md")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.replace, .beside])
    }

    func testDisablingTheNoteGraphDeactivatesTheSections() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertEqual(Set(harness.host.deactivate("note-graph")), ["backlinks", "note-graph"])
        XCTAssertFalse(harness.host.isActive("backlinks"))
        XCTAssertTrue(harness.inspector.all.isEmpty)
        XCTAssertNil(harness.kernel.commands.command(id: "backlinks.mentions"))
        XCTAssertNil(harness.kernel.services.service(BacklinksPlugin.modelKey))
    }

    func testWithoutTheNoteGraphThePluginDoesNotStart() throws {
        let harness = try UIPluginHarness(uiPlugins: [BacklinksPlugin.self], files: files)
        defer { harness.close() }
        XCTAssertFalse(harness.host.isActive("backlinks"))
        XCTAssertTrue(harness.inspector.all.isEmpty)
    }
}
