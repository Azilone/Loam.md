import BuiltinPlugins
import FileExplorerPlugin
@testable import FileExplorerUI
import Foundation
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest

/// The Files panel end to end, through the model its view drives, with the `files` and `note-graph` logic plugins.
@MainActor
final class FileExplorerUITests: XCTestCase {
    private let files = [
        "Welcome.md": "# Welcome\n\nStart with [Spark](Ideas/Spark.md).\n",
        "Ideas/Spark.md": "# A spark\n",
        "Projects/Plan.md": "# Plan\n",
        "Projects/Sub/Deep.md": "",
        "image.png": "not really a picture",
    ]

    private func harness(withGraph: Bool = true, files: [String: String]? = nil) throws -> UIPluginHarness {
        let logic = Set(withGraph ? ["files", "note-graph"] : ["files"])
        return try UIPluginHarness(
            logicPlugins: builtinPlugins.filter { logic.contains($0.manifest.id) },
            uiPlugins: [FileExplorerUIPlugin.self],
            files: files ?? self.files
        )
    }

    private func model(_ harness: UIPluginHarness) throws -> ExplorerModel {
        try XCTUnwrap(harness.kernel.services.service(FileExplorerUIPlugin.modelKey), "\(harness.report)")
    }

    private func setModified(_ harness: UIPluginHarness, _ dates: [String: TimeInterval]) throws {
        for (path, seconds) in dates {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: seconds)],
                ofItemAtPath: harness.vault.url(path).path
            )
        }
    }

    func testSectionsRegisterInOrderAndRender() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("file-explorer"), "\(harness.report)")
        let sections = harness.panels.sections
        XCTAssertEqual(sections.map(\.id), ["explorer.favorites", "explorer.folders", "explorer.recent"])
        XCTAssertEqual(sections.map(\.isShownByDefault), [true, true, false], "Recent starts hidden")
        XCTAssertTrue(harness.panels.panels(in: .leading).isEmpty)
        let size = CGSize(width: 260, height: 500)
        for section in sections {
            XCTAssertEqual(harness.render(AnyView(section.makeView().frame(width: 260, height: 500)), size: size).frame.size, size)
        }
    }

    func testFoldersLeaveOutRootNotesAndShowFiveUntilMore() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        for index in 1...5 { try harness.vault.write("F\(index)/Note.md", "x") }
        try harness.kernel.refreshVault()
        model.refresh()
        XCTAssertEqual(model.topFolders.count, 7)
        XCTAssertEqual(model.folderRows.map(\.item.path), ["F1", "F2", "F3", "F4", "F5"])
        XCTAssertEqual(model.hiddenFolderCount, 2)
        model.showsAllFolders = true
        XCTAssertEqual(model.folderRows.count, 7)
        XCTAssertFalse(model.folderRows.contains { $0.item.kind != .folder }, "no notes at the root")
        XCTAssertEqual(model.hiddenFolderCount, 0)
    }

    func testTreeListsFoldersFirstWithTitlesAndAttachments() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertEqual(model.items.map(\.path), ["Ideas", "Projects", "image.png", "Welcome.md"])
        XCTAssertEqual(model.items.map(\.name), ["Ideas", "Projects", "image.png", "Welcome"])
        XCTAssertEqual(model.items.map(\.kind), [.folder, .folder, .attachment, .note])
        // Collapsed folders hide their content; opening one shows it, one level deeper.
        XCTAssertEqual(model.rows.map(\.id), ["Ideas", "Projects", "image.png", "Welcome.md"])
        model.toggle("Ideas")
        model.toggle("Projects")
        XCTAssertEqual(model.rows.map(\.id), [
            "Ideas", "Ideas/Spark.md", "Projects", "Projects/Sub", "Projects/Plan.md", "image.png", "Welcome.md",
        ])
        XCTAssertEqual(model.rows.map(\.depth), [0, 1, 0, 1, 1, 0, 0])
        XCTAssertEqual(model.rows[1].item.name, "Spark", "its file name, not its first heading")
        model.collapseAll()
        XCTAssertEqual(model.rows.count, 4)
    }

    func testAFolderAPluginHidesLeavesTheTreeAndComesBack() async throws {
        var files = self.files
        files["assets/photo.png"] = "png"
        let harness = try UIPluginHarness(
            logicPlugins: builtinPlugins.filter { ["files", "attachments"].contains($0.manifest.id) },
            uiPlugins: [FileExplorerUIPlugin.self],
            files: files
        )
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertEqual(model.items.map(\.path), ["assets", "Ideas", "Projects", "image.png", "Welcome.md"])
        _ = try await harness.run("attachments.hide-folder", ["hidden": "true"])
        XCTAssertEqual(model.items.map(\.path), ["Ideas", "Projects", "image.png", "Welcome.md"], "hidden at once")
        XCTAssertTrue(harness.vault.exists("assets/photo.png"), "the files stay")
        _ = try await harness.run("attachments.hide-folder", ["hidden": "false"])
        XCTAssertEqual(model.items.first?.path, "assets")
        XCTAssertEqual(
            ExplorerModel.removing(["Projects/Sub"], from: try XCTUnwrap(harness.kernel.services.service(.files)).tree())
                .first { $0.path == "Projects" }?.children?.map(\.path),
            ["Projects/Plan.md"],
            "at any depth"
        )
    }

    func testTitlesFallBackToFileNamesWithoutTheGraph() throws {
        let harness = try harness(withGraph: false)
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("file-explorer"), "\(harness.report)")
        let model = try model(harness)
        model.toggle("Ideas")
        XCTAssertEqual(model.rows[1].item.name, "Spark")
    }

    func testRecentListsTheFiveLastModifiedNotes() throws {
        var many = files
        many["Old.md"] = ""
        many["Older.md"] = ""
        let harness = try harness(files: many)
        defer { harness.close() }
        try setModified(harness, [
            "Older.md": 1_000, "Old.md": 2_000, "Welcome.md": 3_000, "Projects/Sub/Deep.md": 4_000,
            "Ideas/Spark.md": 5_000, "Projects/Plan.md": 6_000,
        ])
        let model = try model(harness)
        model.refresh()
        XCTAssertEqual(model.recent.map(\.path), [
            "Projects/Plan.md", "Ideas/Spark.md", "Projects/Sub/Deep.md", "Welcome.md", "Old.md",
        ])
        XCTAssertEqual(model.recent.first?.title, "Plan")
        XCTAssertEqual(model.cardItems(for: ExplorerModel.allNotes).map(\.path), [
            "Projects/Plan.md", "Ideas/Spark.md", "Projects/Sub/Deep.md", "Welcome.md", "Old.md", "Older.md",
        ], "All Notes shows the last edited first")
        XCTAssertEqual(model.recent.first?.folder, "Projects")
        model.expanded = Set(model.rows.filter { $0.item.kind == .folder }.map(\.id))
        // Recent rows and tree rows share one list: identical ids made SwiftUI draw the tree rows empty.
        XCTAssertTrue(Set(model.recent.map(\.id)).isDisjoint(with: model.rows.map(\.id)))
    }

    func testAllNotesCardsReadAheadAreTheCardsTheMainThreadWouldRead() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        // The read started at launch, then one from nothing.
        await model.warmingCards?.value
        model.noteCards = [:]
        model.readAhead = [:]
        model.warmAllNotes()
        await model.warmingCards?.value
        let items = model.cardItems(for: ExplorerModel.allNotes)
        XCTAssertEqual(Set(model.readAhead.keys), Set(items.map(\.path)), "every card of the first screen is read ahead")
        let ahead = items.map(model.card(for:))
        XCTAssertTrue(model.readAhead.isEmpty, "a card read ahead is used once")
        model.noteCards = [:]
        XCTAssertEqual(items.map(model.card(for:)), ahead)
    }

    func testClickOpensNotesAndTogglesFolders() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        let welcome = try XCTUnwrap(model.items.first { $0.path == "Welcome.md" })
        model.click(welcome, newTab: false)
        model.click(welcome, newTab: true)
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Welcome.md"), .file("Welcome.md")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.replace, .newTab])
        XCTAssertEqual(model.selected, "Welcome.md")

        let ideas = try XCTUnwrap(model.items.first { $0.path == "Ideas" })
        model.click(ideas, newTab: false)
        XCTAssertTrue(model.expanded.contains("Ideas"))
        model.click(ideas, newTab: false)
        XCTAssertFalse(model.expanded.contains("Ideas"))
        XCTAssertEqual(harness.workspace.opened.count, 2, "a click on a folder leaves the page alone")
        XCTAssertEqual(model.selected, "Welcome.md")
        model.click(ideas, newTab: true)
        XCTAssertEqual(harness.workspace.opened.last?.resource, .folder("Ideas"), "Cmd-click opens its page of cards")
        XCTAssertEqual(harness.workspace.opened.last?.placement, .newTab)
    }

    func testAFolderThatIsAPageOpensOnClickWithThatPagesIcon() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        _ = harness.views.register(ViewType(
            id: "test.collection", title: "Collection", priority: 1, symbol: "tablecells",
            canOpen: { $0 == .folder("Ideas") }, prefers: { $0 == .folder("Ideas") }
        ) { _ in AnyView(EmptyView()) })
        XCTAssertEqual(model.symbol(forFolder: "Ideas", open: false), "tablecells")
        let ideas = try XCTUnwrap(model.items.first { $0.path == "Ideas" })
        model.click(ideas, newTab: false)
        XCTAssertEqual(harness.workspace.opened.last?.resource, .folder("Ideas"))
        XCTAssertEqual(harness.workspace.opened.last?.placement, .replace)
        XCTAssertTrue(model.expanded.contains("Ideas"))
        XCTAssertEqual(model.selected, "Ideas")
        model.click(ideas, newTab: false)
        XCTAssertFalse(model.expanded.contains("Ideas"), "shown already: a second click folds it")
        XCTAssertEqual(harness.workspace.opened.count, 1)
    }

    func testFolderPagesShowSubfoldersThenNotesAndAllNotesShowsEveryNote() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        let projects = model.cards(for: .folder("Projects"))
        XCTAssertEqual(projects.map(\.path), ["Projects/Sub", "Projects/Plan.md"])
        XCTAssertEqual(projects.first?.preview, "1 note")
        XCTAssertEqual(
            Set(model.cards(for: ExplorerModel.allNotes).map(\.path)),
            ["Welcome.md", "Ideas/Spark.md", "Projects/Plan.md", "Projects/Sub/Deep.md"]
        )
        XCTAssertFalse(model.cards(for: .folder("")).contains { $0.path == "image.png" }, "no attachments")
        XCTAssertNotNil(harness.views.viewTypes(for: ExplorerModel.allNotes).first)
        XCTAssertEqual(harness.panels.links.map(\.id), ["explorer.all-notes"])
    }

    func testACardShowsTheViewMeantForItsNote() throws {
        let harness = try harness(files: ["Welcome.md": "# Welcome\n", "Plan.excalidraw.md": "---\ndrawing: yes\n---\n"])
        defer { harness.close() }
        let model = try model(harness)
        let remove = harness.views.register(ViewType(
            id: "test.drawing", title: "Drawing", symbol: "scribble",
            canOpen: { $0.path == "Plan.excalidraw.md" }, prefers: { $0.path == "Plan.excalidraw.md" },
            makeView: { _ in AnyView(EmptyView()) }
        ))
        defer { remove() }
        let cards = model.cards(for: .folder(""))
        let drawing = try XCTUnwrap(cards.first { $0.path == "Plan.excalidraw.md" })
        let embed = try XCTUnwrap(model.cardEmbed(for: drawing))
        XCTAssertEqual(embed.type.id, "test.drawing")
        XCTAssertEqual(embed.context.presentation, .embedded)
        XCTAssertTrue(model.cardEmbed(for: drawing)?.context === embed.context, "the card keeps its view's context")
        XCTAssertNil(model.cardEmbed(for: try XCTUnwrap(cards.first { $0.path == "Welcome.md" })), "a plain note shows its text")
    }

    func testFavoritesAreStarredSavedAndUnstarred() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertTrue(model.favoriteItems.isEmpty)
        model.toggleFavorite("Welcome.md")
        model.toggleFavorite("Ideas")
        XCTAssertEqual(model.favoriteItems.map(\.path), ["Welcome.md", "Ideas"])
        model.toggleFavorite("Welcome.md")
        XCTAssertEqual(model.favorites, ["Ideas"])
    }

    func testFoldersAndNotesArePutInOrderBesideASibling() throws {
        var files = self.files
        files["Archive/Old.md"] = "x"
        files["Projects/Zed.md"] = "x"
        let harness = try harness(files: files)
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertEqual(model.topFolders.map(\.path), ["Archive", "Ideas", "Projects"])

        // Projects above Archive: a reorder, nothing moved on disk.
        model.place("Projects", beside: "Archive", after: false)
        XCTAssertEqual(model.topFolders.map(\.path), ["Projects", "Archive", "Ideas"])
        XCTAssertTrue(harness.vault.exists("Projects/Plan.md"))
        model.place("Ideas", beside: "Projects", after: true)
        XCTAssertEqual(model.topFolders.map(\.path), ["Projects", "Ideas", "Archive"])

        // A note dropped beside one of another folder moves there, at that place.
        model.expanded.insert("Projects")
        model.place("Archive/Old.md", beside: "Projects/Zed.md", after: false)
        XCTAssertTrue(harness.vault.exists("Projects/Old.md"))
        let children = model.rows.filter { $0.depth == 1 }.map(\.item.path)
        XCTAssertEqual(Array(children.suffix(2)), ["Projects/Old.md", "Projects/Zed.md"])

        // The order is kept in the settings and follows a rename.
        XCTAssertNotNil(model.rename("Projects", to: "Work"))
        XCTAssertEqual(model.topFolders.map(\.path), ["Work", "Ideas", "Archive"])
        XCTAssertTrue(model.order.contains("Work/Old.md"))

        // A folder never goes beside its own content.
        model.place("Work", beside: "Work/Zed.md", after: false)
        XCTAssertTrue(harness.vault.exists("Work/Zed.md"))
    }

    func testTheInboxComesFirstWithATray() throws {
        var files = self.files
        files["Inbox/Idea.md"] = "x"
        let harness = try harness(files: files)
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertEqual(model.topFolders.map(\.path), ["Inbox", "Ideas", "Projects"])
        XCTAssertEqual(model.icon(forFolder: "Inbox", open: false), .symbol("tray"))
        XCTAssertEqual(model.icon(forFolder: "Ideas", open: true), .symbol("folder.fill"))
    }

    func testPluginFoldersComeLastAndNewNotesNeverLandInThem() throws {
        var files = self.files
        files["Daily/2026-10-27.md"] = "x"
        files["Areas/Work.md"] = "x"
        let harness = try harness(files: files)
        defer { harness.close() }
        let model = try model(harness)
        model.managedFolders = { ManagedFolders(paths: ["Daily", "Projects"]) }
        model.refresh()
        XCTAssertEqual(model.topFolders.map(\.path), ["Areas", "Ideas", "Daily", "Projects"])
        let managed = ManagedFolders(paths: ["Daily", "Projects"])
        XCTAssertEqual(managed.newItemFolder(from: "Daily"), "Inbox")
        XCTAssertEqual(managed.newItemFolder(from: "Projects/Site"), "Inbox")
        XCTAssertEqual(managed.newItemFolder(from: "Areas"), "Areas")
        XCTAssertEqual(managed.newItemFolder(from: ""), "Inbox")
        XCTAssertEqual(managed.newItemFolder(from: nil), "Inbox")
        XCTAssertEqual(ExplorerModel.folders(in: [
            FileNode(path: "A", isFolder: true, children: [FileNode(path: "A/B", isFolder: true, children: []),
                                                           FileNode(path: "A/n.md", isFolder: false, children: nil)]),
        ]), ["A", "A/B"])
    }

    func testAFolderKeepsTheIconAndColorItIsGivenWhenItMoves() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.setFolderStyle("Projects/Sub", FolderStyle(icon: "🚀", color: "#2F66F6"))
        model.setFolderStyle("Ideas", FolderStyle(icon: "lightbulb"))
        XCTAssertEqual(model.icon(forFolder: "Projects/Sub", open: false), .emoji("🚀"))
        XCTAssertEqual(model.icon(forFolder: "Ideas", open: false), .symbol("lightbulb"))
        XCTAssertEqual(FolderTint.color(for: "Projects/Sub"), FolderTint.color(hex: "#2F66F6"))

        _ = model.rename("Projects", to: "Work")
        XCTAssertEqual(model.folderStyle("Work/Sub").icon, "🚀", "follows the rename")
        XCTAssertTrue(model.folderStyle("Projects/Sub").isEmpty)
        let config = try harness.vault.read(".loam/config.json")
        XCTAssertTrue(config.contains("Work/Sub") && !config.contains("Projects/Sub"), "saved in the settings: \(config)")

        model.setFolderStyle("Ideas", FolderStyle())
        XCTAssertEqual(model.icon(forFolder: "Ideas", open: false), .symbol("folder"), "reset")
    }

    func testThePickerDraws() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.setFolderStyle("Ideas", FolderStyle(icon: "lightbulb", color: "#2F66F6"))
        let hosting = NSHostingView(rootView: FolderStylePicker(model: model, path: "Ideas").fixedSize())
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.width, 320, accuracy: 1)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let dir = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("folder-style-picker.png"))
        }
    }

    func testIconSearchFindsSymbolsAndEmojiByName() {
        XCTAssertTrue(FolderIconCatalog.symbols(matching: "cal").contains("calendar"))
        XCTAssertTrue(FolderIconCatalog.emoji(matching: "rocket").contains("🚀"))
        XCTAssertEqual(FolderIconCatalog.emoji(matching: "🦄"), ["🦄"], "an emoji typed is offered")
        XCTAssertTrue(FolderIcon.isEmoji("❤️"))
        XCTAssertFalse(FolderIcon.isEmoji("tray"))
        XCTAssertFalse(FolderIcon.isEmoji("1"))
    }

    func testCardPreviewDropsTheTitleAndTheSyntax() {
        let text = "---\ntags: [a]\n---\n# Title\n\nSee **this** [link](x.md) and [[Note|alias]].\n- [ ] a task\n"
        XCTAssertEqual(ExplorerModel.preview(of: text, title: "Title"), "See this link and alias.\na task")
        XCTAssertEqual(ExplorerModel.preview(of: "# Other\nText\n", title: "Title"), "Other\nText")
    }

    func testSelectionFollowsTheActiveTabAndRevealOpensItsFolders() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        harness.kernel.events.emit(ActiveResourceChanged(resource: .file("Projects/Sub/Deep.md")))
        XCTAssertEqual(model.selected, "Projects/Sub/Deep.md")
        XCTAssertFalse(model.expanded.contains("Projects/Sub"))

        harness.workspace.activeResource = .file("Projects/Sub/Deep.md")
        let answer = try await harness.run("explorer.reveal-active")
        XCTAssertEqual(answer, "Projects/Sub/Deep.md")
        XCTAssertEqual(model.expanded, ["Projects", "Projects/Sub"])
        XCTAssertTrue(model.rows.contains { $0.id == "Projects/Sub/Deep.md" })
    }

    func testAnEmptyNoteThatWasAlreadyOnDiskIsLeftAloneWhenTheFocusMovesOn() throws {
        let harness = try harness(files: ["Blank.md": "\n  \n", "Kept.md": "x"])
        defer { harness.close() }
        harness.kernel.events.emit(ActiveResourceChanged(resource: .file("Blank.md")))
        harness.kernel.events.emit(ActiveResourceChanged(resource: .file("Kept.md")))
        XCTAssertTrue(harness.vault.exists("Blank.md"), "a user's notes change only when asked")
        XCTAssertFalse(harness.vault.exists(".trash/Blank.md"))
    }

    func testNewNoteIsADraftThatWritesNothing() async throws {
        let editor = RecordingEditor()
        let harness = try UIPluginHarness(
            logicPlugins: builtinPlugins.filter { ["files", "note-graph"].contains($0.manifest.id) },
            uiPlugins: [FileExplorerUIPlugin.self], files: files, editor: editor
        )
        defer { harness.close() }
        harness.workspace.activeResource = .file("Projects/Plan.md")
        let path = try await harness.run("explorer.new-note")
        XCTAssertEqual(path, "Projects/Untitled.md")
        XCTAssertFalse(harness.vault.exists(path), "the file appears once text is typed")
        XCTAssertEqual(editor.drafts.map(\.path), [path])
        XCTAssertEqual(harness.workspace.opened.last?.resource, .file(path))
        let second = try await harness.run("explorer.new-note")
        XCTAssertEqual(second, "Projects/Untitled 2.md", "a draft still open keeps its name")
        let note = try model(harness)
        XCTAssertFalse(note.rows.contains { $0.id == path }, "a draft is only its tab, not a row")
    }

    func testNewNoteCommandCreatesInTheActiveNotesFolderAndOpensIt() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        let command = try XCTUnwrap(harness.kernel.commands.command(id: "explorer.new-note"))
        XCTAssertNil(command.shortcut, "Cmd+N is the new-tab variant's")

        harness.workspace.activeResource = .file("Projects/Plan.md")
        let path = try await harness.run("explorer.new-note")
        XCTAssertEqual(path, "Projects/Untitled.md")
        XCTAssertEqual(try harness.vault.read("Projects/Untitled.md"), "")
        XCTAssertEqual(harness.workspace.opened.last?.resource, .file("Projects/Untitled.md"))
        XCTAssertEqual(harness.workspace.opened.last?.placement, .replace)
        XCTAssertTrue(model.rows.contains { $0.id == "Projects/Untitled.md" }, "its folder opens in the tree")

        harness.workspace.activeResource = nil
        let inInbox = try await harness.run("explorer.new-note")
        XCTAssertEqual(inInbox, "Inbox/Untitled.md", "no note lands at the root")

        harness.workspace.activeResource = .file("Top.md")
        let besideARootNote = try await harness.run("explorer.new-note")
        XCTAssertEqual(besideARootNote, "Inbox/Untitled 2.md")
    }

    func testCmdNOpensTheNewNoteInANewTab() async throws {
        let editor = RecordingEditor()
        let harness = try UIPluginHarness(
            logicPlugins: builtinPlugins.filter { ["files", "note-graph"].contains($0.manifest.id) },
            uiPlugins: [FileExplorerUIPlugin.self], files: files, editor: editor
        )
        defer { harness.close() }
        let command = try XCTUnwrap(harness.kernel.commands.command(id: "explorer.new-note-in-tab"))
        XCTAssertEqual(command.shortcut, KeyShortcut("n", [.command]))

        harness.workspace.activeResource = .file("Projects/Plan.md")
        let path = try await harness.run("explorer.new-note-in-tab")
        XCTAssertEqual(path, "Projects/Untitled.md", "the active note's folder, like New note")
        XCTAssertFalse(harness.vault.exists(path), "still a draft")
        XCTAssertEqual(editor.drafts.map(\.path), [path])
        XCTAssertEqual(harness.workspace.opened.last?.resource, .file(path))
        XCTAssertEqual(harness.workspace.opened.last?.placement, .newTab)

        harness.workspace.activeResource = nil
        let inInbox = try await harness.run("explorer.new-note-in-tab")
        XCTAssertEqual(inInbox, "Inbox/Untitled.md")
    }

    func testNewFolderStartsRenamingAndReturnCommits() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.newFolder(in: "Projects")
        XCTAssertTrue(harness.vault.exists("Projects/New folder"))
        XCTAssertEqual(model.renaming, "Projects/New folder")
        XCTAssertEqual(model.renameText, "New folder")
        XCTAssertTrue(model.rows.contains { $0.id == "Projects/New folder" }, "an empty folder shows at once")
        model.renameText = "Archive"
        model.commitRename()
        XCTAssertNil(model.renaming)
        XCTAssertTrue(harness.vault.exists("Projects/Archive"))
        XCTAssertTrue(model.rows.contains { $0.id == "Projects/Archive" })
    }

    func testNewTopFolderPastTheLimitShowsEveryFolder() throws {
        let harness = try harness()
        defer { harness.close() }
        for name in ["A1", "A2", "A3", "A4", "A5", "A6"] { try harness.vault.createFolder(name) }
        let model = try model(harness)
        model.refresh()
        XCTAssertFalse(model.showsAllFolders)
        model.newFolder(in: "")
        XCTAssertEqual(model.renaming, "New folder")
        XCTAssertTrue(model.folderRows.contains { $0.id == "New folder" }, "renamed in sight, not under \"more\"")
    }

    func testRenameKeepsTheExtensionAndRewritesLinks() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.toggle("Ideas")
        model.beginRename("Ideas/Spark.md")
        XCTAssertEqual(model.renameText, "Spark", "the file name without .md, not the title")
        model.renameText = "Flame"
        model.commitRename()
        XCTAssertFalse(harness.vault.exists("Ideas/Spark.md"))
        XCTAssertTrue(harness.vault.exists("Ideas/Flame.md"))
        XCTAssertTrue(try harness.vault.read("Welcome.md").contains("(Ideas/Flame.md)"))
        XCTAssertTrue(model.rows.contains { $0.id == "Ideas/Flame.md" })

        model.beginRename("image.png")
        model.cancelRename()
        XCTAssertNil(model.renaming)
        XCTAssertEqual(model.rename("image.png", to: "photo.png"), "photo.png", "attachments keep the typed name")
    }

    func testRenameIsInTheMenusOfTabsAndPagesButNotTwiceInThePanel() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        for path in ["Ideas/Spark.md", "image.png"] {
            XCTAssertEqual(harness.resourceActions.actions(for: .file(path)).map(\.id), ["explorer.rename"], path)
        }
        XCTAssertEqual(harness.resourceActions.actions(for: .folder("Projects")).map(\.id), ["explorer.rename"])
        XCTAssertTrue(harness.resourceActions.actions(for: .file("Gone.md")).isEmpty, "nothing to rename")
        XCTAssertTrue(harness.resourceActions.actions(for: .virtual("notes:All Notes#x")).isEmpty)
        XCTAssertTrue(model.actions(.file("Ideas/Spark.md")).isEmpty, "the row has its own Rename")
    }

    func testAFileAViewOpensShowsItsIconAndRenamesLikeANote() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        try harness.kernel.refreshVault()
        try harness.vault.write("Boards/Plan.canvas", "{}")
        XCTAssertEqual(try harness.kernel.refreshVault(), [VaultChange(kind: .added, path: "Boards/Plan.canvas")])
        await model.settled()
        model.toggle("Boards")
        let board = try XCTUnwrap(model.rows.first { $0.id == "Boards/Plan.canvas" }?.item, "VaultChanged on a .canvas")
        let image = try XCTUnwrap(model.items.first { $0.path == "image.png" })
        XCTAssertEqual(board.kind, .attachment)
        XCTAssertEqual(model.symbol(forFile: board.path), "doc")
        XCTAssertEqual(model.title(of: board), "Plan.canvas", "no view opens it yet")

        let remove = harness.views.register(ViewType(
            id: "test.board",
            title: "Board",
            symbol: "square.on.square",
            canOpen: { $0.pathExtension == "canvas" },
            makeView: { _ in AnyView(EmptyView()) }
        ))
        defer { remove() }
        XCTAssertEqual(model.symbol(forFile: board.path), "square.on.square", "the icon of the view that opens it")
        XCTAssertEqual(model.symbol(forFile: image.path), "doc")
        XCTAssertEqual(model.title(of: board), "Plan")
        XCTAssertEqual(model.title(of: image), "image.png")

        model.beginRename(board.path)
        XCTAssertEqual(model.renameText, "Plan", "the name without its extension")
        model.renameText = "Road map"
        model.commitRename()
        XCTAssertTrue(harness.vault.exists("Boards/Road map.canvas"), "the extension stays")
        XCTAssertEqual(model.rename("Boards/Road map.canvas", to: "Ideas.canvas"), "Boards/Ideas.canvas", "not doubled")
        XCTAssertEqual(model.rename("image.png", to: "photo"), "photo", "a plain attachment takes the typed name")
    }

    func testADrawingKeepsItsSecondExtensionWhenRenamed() throws {
        let harness = try harness(files: ["Inbox/Drawing.excalidraw.md": "", "Inbox/v1.2 notes.md": ""])
        defer { harness.close() }
        let model = try model(harness)
        let remove = harness.views.register(ViewType(
            id: "test.drawing", title: "Drawing", priority: 10, symbol: "scribble",
            canOpen: { $0.path.hasSuffix(".excalidraw.md") }, makeView: { _ in AnyView(EmptyView()) }
        ))
        defer { remove() }
        model.beginRename("Inbox/Drawing.excalidraw.md")
        XCTAssertEqual(model.renameText, "Drawing")
        XCTAssertEqual(model.rename("Inbox/Drawing.excalidraw.md", to: "Mood board"), "Inbox/Mood board.excalidraw.md")
        XCTAssertEqual(model.rename("Inbox/Mood board.excalidraw.md", to: "Moods.md"), "Inbox/Moods.excalidraw.md")
        XCTAssertEqual(model.rename("Inbox/v1.2 notes.md", to: "v1.3"), "Inbox/v1.3.md", "a dot in a note's name is no extension")
    }

    func testANameConflictShowsAMessageAndChangesNothing() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        try harness.vault.write("Ideas/Plan.md", "")
        XCTAssertNil(model.move("Projects/Plan.md", into: "Ideas"))
        XCTAssertEqual(model.message, "“Plan.md” already exists there.")
        XCTAssertTrue(harness.vault.exists("Projects/Plan.md"))
    }

    func testDroppingANoteOnAFolderMovesItThere() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.drop(.resource(.file("Welcome.md")), into: "Projects")
        XCTAssertTrue(harness.vault.exists("Projects/Welcome.md"))
        XCTAssertFalse(model.items.contains { $0.path == "Welcome.md" })
        XCTAssertTrue(model.expanded.contains("Projects"))
        XCTAssertTrue(try harness.vault.read("Projects/Welcome.md").contains("(../Ideas/Spark.md)"))

        // On the empty area: back to the root. A tab is not a file: ignored.
        model.drop(.resource(.file("Projects/Welcome.md")), into: "")
        XCTAssertTrue(harness.vault.exists("Welcome.md"))
        model.drop(.tab(UUID()), into: "Projects")
        XCTAssertNil(model.message)
    }

    func testDroppingAFolderIntoItselfIsRefused() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.drop(.resource(.folder("Projects")), into: "Projects/Sub")
        XCTAssertEqual(model.message, "A folder cannot move into itself.")
        XCTAssertTrue(harness.vault.exists("Projects/Sub/Deep.md"))
    }

    func testDeleteAfterConfirmationMovesToTheTrash() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.requestDelete("Welcome.md")
        XCTAssertEqual(model.pendingDelete, "Welcome.md")
        XCTAssertTrue(harness.vault.exists("Welcome.md"), "nothing moves before the confirmation")
        model.confirmDelete()
        XCTAssertNil(model.pendingDelete)
        XCTAssertFalse(harness.vault.exists("Welcome.md"))
        XCTAssertTrue(harness.vault.exists(".trash/Welcome.md"))
        XCTAssertFalse(model.items.contains { $0.path == "Welcome.md" })
        XCTAssertFalse(model.recent.contains { $0.path == "Welcome.md" })
    }

    func testRefreshesOnVaultChanged() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        try harness.kernel.refreshVault()
        await model.settled()
        try harness.vault.write("Later.md", "# Later\n")
        XCTAssertFalse(model.items.contains { $0.path == "Later.md" })
        try harness.kernel.refreshVault()
        XCTAssertFalse(model.items.contains { $0.path == "Later.md" }, "read off the main thread")
        await model.settled()
        XCTAssertTrue(model.items.contains { $0.path == "Later.md" })
    }

    func testDisablingTheFilesServiceDeactivatesThePanel() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertEqual(harness.host.deactivate("files"), ["file-explorer", "files"])
        XCTAssertFalse(harness.host.isActive("file-explorer"))
        XCTAssertTrue(harness.panels.sections.isEmpty)
        XCTAssertNil(harness.kernel.commands.command(id: "explorer.new-note"))
        XCTAssertNil(harness.kernel.services.service(FileExplorerUIPlugin.modelKey))
    }
}
