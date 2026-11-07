import Foundation
import LoamCore
import PluginKit

/// `loam guide [topic]`: what an outside agent (Claude Code, Codex, Pi…) needs to work in Loam and build plugins for
/// it. The agent skill (`AgentSkill`) only says to read this, so the knowledge ships with the app and stays true to
/// its version.
public enum Guide {
    public struct Topic {
        public let name: String
        public let summary: String
        public let text: String
    }

    /// The topics, in reading order.
    public static var topics: [Topic] {
        [
            Topic(name: "notes", summary: "how notes, tasks, daily notes and collections are written", text: notes),
            Topic(name: "recipes", summary: "make each kind of note: project + Kanban, meeting, habit, mind map, board, drawing",
                  text: recipes),
            Topic(name: "commands", summary: "everything the app can do, as commands: search, tasks, daily notes…",
                  text: commands),
            Topic(name: "migrate", summary: "move the user's notes from any other app into a new Loam vault",
                  text: migrate),
            Topic(name: "plugins", summary: "build a plugin, step by step: the API, the rules, the pitfalls",
                  text: plugins),
            Topic(name: "ui", summary: "plugins with a panel, a page, a slash item or a window overlay", text: ui),
            Topic(name: "test", summary: "test a plugin before anyone runs it", text: test),
            Topic(name: "app", summary: "drive the open app: open a note, run a command, screenshot, relaunch",
                  text: app),
            Topic(name: "share", summary: "share a plugin, install someone's", text: share),
        ]
    }

    /// The text for `topic`, or the overview without one.
    public static func text(_ topic: String?) -> String? {
        guard let topic, !topic.isEmpty else { return header + overview }
        return topics.first { $0.name == topic.lowercased() }.map { header + $0.text }
    }

    static var header: String {
        "Loam CLI · plugin SDK \(PluginSDKVersion.current.major).\(PluginSDKVersion.current.minor) · guide\n\n"
    }

    static var overview: String {
        """
        # Loam

        Loam is a local-first Markdown notebook for the Mac. A vault is a plain folder of Markdown notes, and
        everything beyond writing is a plugin. Every action of every plugin is a command you can run from here, so
        whatever the user does in the app, you can do with `loam`.

        Which vault: `loam app info` prints the vault open in the app. Otherwise pass `--vault <folder>`, set
        `LOAM_VAULT`, or run `loam` from inside the vault.

        Rules:
        - The notes are the user's. Change them only when asked, and say which notes you changed.
        - Never write in `.loam/cache/`, `.git/` or `.trash/`. `.loam/config.json` changes through commands
          (`plugins.enable`, `plugins.set-setting`), not by hand.
        - Plain formats only: CommonMark + GFM, YAML frontmatter, [[wikilinks]]. Never invent a syntax or a file
          format.
        - The app watches the folder: a note you write shows at once in the open window.

        Read the topic you need (`loam guide <topic>`):

        \(topics.map { "  \($0.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.summary)" }.joined(separator: "\n"))

        `loam --help` lists the CLI's own verbs; `loam list` lists every command with what it does.

        """
    }

    static var notes: String {
        """
        # Notes

        A note is a `.md` file anywhere in the vault: CommonMark + GitHub Flavored Markdown.

        - Properties: YAML frontmatter at the top (`---` … `---`). `tags: [a, b]`, dates as `YYYY-MM-DD`.
        - Links: `[[Note name]]` or `[[Folder/Note|label]]` between notes; standard Markdown links elsewhere.
        - Tags: `#tag` or `#tag/sub` in the text, or `tags:` in the frontmatter.
        - Tasks: a GFM task line in any note, with optional metadata kept as plain text:
          `- [ ] Ship the beta 📅 2026-10-20 #work ⏫` (due `📅 date` or `due:date`, priority `⏫`/`!high` or
          `🔽`/`!low`, done `- [x] … ✅ 2026-10-17`). `loam tasks.list`, `loam tasks.add`, `loam tasks.toggle`.
        - Daily notes: one note per day; `loam daily.path` prints today's path (the folder is a setting),
          `loam daily.append text="…"` adds to it.
        - Collections: a `.base` file (Obsidian Bases YAML) shows a set of notes as a table, a board or a gallery;
          its fields are the notes' frontmatter. Use `loam collection.*` rather than editing it by hand.
        - Boards: `.canvas` files (JSON Canvas); drawings: `.excalidraw.md`. Use `loam canvas.*` and
          `loam excalidraw.*`. Projects, meetings, habits and mind maps: `loam guide recipes`.
        - Attachments go in the attachments folder through `loam attachments.import`.

        Editing a note directly is fine: write the whole file, keep the frontmatter and the user's formatting, and
        read it right before you write (the user may be typing in it).

        """
    }

    static var migrate: String {
        """
        # Migrate notes into Loam

        The user wants their notes from another app (Notion, Obsidian, Roam, Craft, Bear, Evernote, Apple Notes,
        Logseq, anything) in a new Loam vault. You do the whole migration: the user answers three questions, then
        waits. Speak the user's language.

        ## Ask these three questions, in this order, and nothing else

        1. Which app the notes come from.
        2. Where its export is. If they have none, look up that app's current export instructions and walk them
           through it: a Markdown export if the app has one, else its richest format (HTML, JSON, .enex…). Apps
           Loam reads directly need no export: an Obsidian vault folder, Bear, Apple Notes.
        3. Keep their folders as they are, or let you reorganize them for Loam (properties, collections, daily
           notes, fewer folders)? Keeping is the default.

        Then work to the end without asking again.

        ## Rules

        - The source is read-only: never change, move or delete a file of the export or of the other app.
        - Write into a new vault, `~/Documents/<source name>` (the Obsidian vault's name, or the app's name);
          if that folder exists, add " 2", " 3"… Never write into another vault, never overwrite a file. When the
          user names the vault to write into, that is the one (it is theirs to choose).
        - Run every `loam` command with `--vault <new vault>`.
        - Plain formats only, as `loam guide notes` describes them. Convert:
          - pages and notes: one `.md` file each, named after the title (no `/` or `:`), folders as in the source
          - metadata and page properties: YAML frontmatter (`created`, `updated`, `tags`…), dates `YYYY-MM-DD`
          - links between notes: `[[Note name]]`; links to the web stay as they are
          - databases and tables of pages: one note per row, its fields as frontmatter, and a collection
            (`loam collection.*`) showing them
          - to-dos: task lines, `- [ ] Text 📅 2026-10-20`
          - projects: a project is something with an outcome and, usually, tasks and a deadline: a Notion project
            or a page of a "Projects" database, an Obsidian note tagged `project` or filed under PARA's projects,
            a Craft or Bear project folder, a list of to-dos under one goal. When the source has some, make real
            Loam projects (`loam guide recipes`): `loam projects.new title=… due=…`, its open tasks as cards
            (`projects.add-task`, status from the source: To do, In progress, Done), its other notes moved inside
            the project's `Notes/` folder with `files.move` (so links follow). Take status, deadline and tasks
            from the source's own fields, invent none. A note that is only a topic (a resource, an area of life,
            test or sample data) is not a project: leave it where it is and list it under "To check"
          - journals and daily pages: daily notes, in the folder `loam daily.path` prints, one file per day named
            `YYYY-MM-DD.md`, whatever the source called them (`2026.07.28`, `Mon 14 Jul 2025`); Loam's calendar
            and `daily.*` commands only see them there. Two notes of one day: merge them into one
          - attachments (images, PDFs, audio): in the vault's attachments folder (`loam attachments.import`
            copies a file there under a free name), linked from the notes that use them; never drop one, never
            leave them in a folder of their own beside the notes
          - block references and transclusions: the text inlined, or a link to its heading
          - whiteboards: `.canvas` (JSON Canvas); drawings: `.excalidraw.md`
          - anything with no equivalent: kept as plain text or a code block, and listed in the log
        - Use the importers built into Loam first, then finish what they report as lost: `import.obsidian`,
          `import.notion`, `import.bear`, `import.apple-notes` (`loam list import` shows their arguments; pass an
          empty `into=`, so the notes land at the vault's root, where `import.obsidian` also puts daily notes and
          attachments where Loam keeps them). They are fast and tested. For any other app, write your own
          conversion script that follows the same layout.

        ## The log, and resuming

        Keep `Migration log.md` at the vault's root, updated as you go:

          ---
          source: Notion
          export: ~/Downloads/Export-1234.zip
          status: running
          ---
          ## Done        what is converted, with counts
          ## To check    broken links, notes that may have lost something
          ## Lost        what Loam has no equivalent for

        If the vault and its log already exist with `status: running`, you are resuming: keep the notes already
        written and carry on from where the log stops.

        ## Finish

        1. Check: count the source's notes against the vault's (`loam notes.list`), the source's journal days
           against `loam daily.list`, the projects against `loam projects.list`, and look for links to notes or files that do not exist. Fix what you can,
           list the rest under "To check".
        2. Set `status: done` in the log.
        3. Open the vault in Loam: `loam app switch <vault>` when Loam is running, else
           `open -a Loam --args --vault <vault>`.
        4. Tell the user, in a few lines: how many notes, where, and that the log lists what to check.

        """
    }

    static var recipes: String {
        "# Recipes\n\n" + AgentRecipes.text() + "\n\n"
    }

    static var commands: String {
        """
        # Commands

        `loam list` prints every command as JSON: id, title, and a summary that names its arguments; `loam list
        <word>` keeps the ones matching a word, `loam list --brief` prints one line each. Run one with
        `loam <id> key=value …`; it prints its result (often JSON) on stdout, or a JSON error on stderr with a
        non-zero exit.

        The ones agents use most:

          loam search.content q="…"             full text; search.meaning for meaning, search.names for titles
          loam notes.list | notes.backlinks path=…   the notes, and what links to one
          loam files.new-note path=…             also files.move, files.new-folder, files.trash (never rm)
          loam daily.append text="…"             today's note; daily.read, daily.path
          loam tasks.list / tasks.add / tasks.toggle
          loam query.run …                       notes by folder, tag and property; query.set-property
          loam collection.list / collection.entries / collection.set-property
          loam habits.status / habits.check name=…
          loam plugins.list / plugins.enable id=… / plugins.settings id=…

        Commands of the plugins the vault turned off are not there; `loam plugins.list` says which are off.
        Commands that only make sense in the window (open a panel, toggle the Assistant) run in the open app:
        `loam app run <id>` (see `loam guide app`).

        """
    }

    static var plugins: String {
        let sdk = (try? PluginSDK.locate().get()).map { $0.url.path } ?? "<the SDK was not found>"
        return """
        # Build a plugin

        A plugin is a small Swift package in the vault, `.loam/plugins/<id>/`, compiled on this Mac against the
        app's SDK and loaded by the app. It adds commands, services, event listeners, and with a UI part, views and
        panels (`loam guide ui`). Its data is plain Markdown in the vault.

        The SDK, to read the exact API: \(sdk)
          Sources/PluginKit/            Plugin, PluginContext, Command, PluginManifest, the vault, events, settings
          App/Sources/PluginKitUI/      UIPlugin, views, panels, slash items, overlays, Motion, theme tokens
          Sources/Plugins/HabitTracker/ a complete first-party plugin (logic); App/Sources/Plugins/HabitsUI its UI

        ## The steps

        1. Pick an id: kebab-case, starting with a letter (`reading-tracker`). It names the folder, and in PascalCase
           the module (`ReadingTracker`) and the class (`ReadingTrackerPlugin`).
        2. `loam plugin new <id>` (add `--ui` for a panel or a page). It writes a working package:
           plugin.json, Package.swift, Sources/<Module>/<Module>Plugin.swift, a test and a README. Read them first.
        3. Write the plugin in Sources/<Module>/. Keep the Package.swift as generated.
        4. `loam plugin build <id>`. It prints JSON {ok, library, log}; when ok is false, the log's last lines say
           why. Fix and build again until ok.
        5. `loam plugin test <id>`, and add tests for what you wrote (`loam guide test`).
        6. Tell the user what it does and the permissions in plugin.json, then `loam plugin enable <id>` once
           they agree.
        7. Run its commands: `loam <id>.<verb> …`. With a UI, `loam app relaunch` loads the new code in the open
           app (code is never reloaded in place), then `loam app shot /tmp/loam.png` and look at the picture.

        ## The code

        ```swift
        import PluginKit

        public final class ReadingTrackerPlugin: Plugin {
            public static var manifest: PluginManifest {
                PluginManifest(id: "reading-tracker", name: "Reading tracker", version: "0.1.0",
                               description: "Books you read, one note each.", icon: "books.vertical",
                               permissions: ["vault.read", "vault.write"])
            }

            public required init() {}

            public func activate(context: PluginContext) throws {
                try context.registerCommand(Command(
                    id: "reading-tracker.add",
                    title: "Add a book",
                    summary: "Creates a note for a book in Reading/. Arguments: title; optional: author. Returns its path."
                ) { [weak context] arguments in
                    guard let context else { return "" }
                    let title = try arguments.require("title")
                    let path = "Reading/\\(title).md"
                    try context.vault.write(path, "---\\nauthor: \\(arguments["author"] ?? "")\\nstatus: reading\\n---\\n")
                    return path
                })
            }
        }
        ```

        - Everything is registered through `context` (commands, services, `context.on(Event.self)`,
          `context.effect { … }` for cleanup) and undone when the plugin turns off. No global state.
        - A command's `summary` is what agents read: say what it does, name its arguments, say if it writes.
        - Read and write notes only through `context.vault` (`read`, `write`, `exists`, `move`, `list`,
          `markdownPaths`), with vault-relative paths. Read a note right before you change it.
        - Settings: one `Codable` struct read with `context.settings.value(default:)` in `activate`, described in
          the manifest's `settings:`; Settings > Plugins shows them without UI code.
        - Other plugins' features: `context.service(.<key>)` with the id in `requires` or `optionalRequires`
          (`noteQuery`, `tasks`, `dailyNotes`, `editor`…). Plugins never import each other.
        - The entry point at the end of the main file (`@_cdecl("loam_plugin_entry")`) is generated: keep it, and
          add any other plugin class of the package to its list.

        ## The rules `loam plugin build` checks, and the ones it cannot

        - Import only `PluginKit` (and `PluginKitUI`, SwiftUI, Foundation). Anything else from Loam is refused: it
          changes with every release.
        - Every plugin class of the package has the package's id, or the id and a dot (`reading-tracker.extra`).
          Name commands, views and panels `<id>.<verb>` too: ids are shared by every plugin of the app.
        - plugin.json `permissions` say what it touches: vault.read, vault.write, network, shell, disk.read, audio,
          clipboard, ui. Declare all, ask the user before enabling.
        - Plain Markdown and existing conventions only; never a new file format, never a database.
        - Switch over SDK enums with `@unknown default:`.
        - A logic plugin builds on Linux: Foundation only outside the UI part.
        - After an app update that changes the SDK's major version, rebuild.

        """
    }

    static var ui: String {
        """
        # Plugins with an interface

        `loam plugin new <id> --ui` makes a package with a UI module: a `UIPlugin` whose
        `@MainActor func activateUI(context:)` registers, through the context:

          context.registerView(ViewType(id:title:canOpen:makeView:))   a page that opens in a tab
          context.registerPanel(Panel(id:title:symbol:slot:) { … })     a sidebar (.leading, .trailing) or status bar panel
          context.addSidebarLink(SidebarLink(…))                       a row of the left sidebar's navigation
          context.addSlashItem(SlashItem(…))                           an item of the `/` menu in notes
          context.addWindowOverlay(WindowOverlay(…))                   a view floating over the window's corner
          context.addSettingsSection(SettingsSection(…))               a part of its page in Settings
          context.registerCommand(Command(…))                          the same actions, for the palette and agents

        ```swift
        import PluginKit
        import PluginKitUI
        import SwiftUI

        public final class ReadingTrackerUIPlugin: UIPlugin {
            public static let manifest = PluginManifest(id: "reading-tracker.ui", name: "Reading tracker", version: "0.1.0",
                                                        permissions: ["ui", "vault.read"])
            public init() {}

            @MainActor public func activateUI(context: PluginContext) throws {
                let model = Books(context: context)
                try context.registerPanel(Panel(id: "reading-tracker.panel", title: "Books", symbol: "books.vertical",
                                                slot: .trailing) {
                    AnyView(BooksList(model: model))
                })
                // Refresh when the notes change, from the app or from an agent.
                context.on(VaultChanged.self) { [weak model] _ in
                    DispatchQueue.main.async { model?.reload() }
                }
            }
        }

        /// Main-actor state; closures given to the context capture this, never the context.
        @MainActor @Observable final class Books {
            private let context: PluginContext
            var titles: [String] = []
            init(context: PluginContext) { self.context = context; reload() }
            func reload() {
                titles = ((try? context.vault.markdownPaths()) ?? []).filter { $0.hasPrefix("Reading/") }
            }
            func open(_ path: String) { context.workspace?.open(.file(path), placement: .replace) }
        }
        ```

        The shell is reached only through `context.workspace` (open a resource), `context.quickPick` (a filterable
        popup), `context.toasts` and `context.editor`. Views are SwiftUI; take colours from the environment's
        `themeTokens` and animations from `Motion` (PluginKitUI), and honour Reduce Motion. Keep the logic (data,
        commands) in the logic module so the CLI and agents can do everything without the window.

        Look: the app copies Craft's design (rounded white cards on a light grey, SF fonts, 13-point UI text).
        Check your view: `loam app relaunch`, open it (`loam app run <id>.open` or `loam app open …`), then
        `loam app shot /tmp/loam.png` and read the image.

        """
    }

    static var test: String {
        """
        # Test a plugin

        `loam plugin test <id>` runs the package's tests (`swift test` against the app's SDK) and prints JSON
        {ok, log}.

        A logic test builds a kernel on a temporary vault, activates the plugin, runs its commands and checks the
        files:

        ```swift
        import PluginKitTesting
        import XCTest
        @testable import ReadingTracker

        final class ReadingTrackerTests: XCTestCase {
            func testAddWritesANote() async throws {
                let harness = try PluginTestHarness([ReadingTrackerPlugin.self])
                let path = try await harness.run("reading-tracker.add", ["title": "Dune"])
                XCTAssertEqual(path, "Reading/Dune.md")
                XCTAssertTrue(try harness.vault.read(path).contains("status: reading"))
                harness.host.deactivateAll()
            }
        }
        ```

        A UI test uses `UIPluginHarness` (PluginKitUITesting): the host services, a recording workspace and quick
        pick, and `render(_:)` to lay a view out offscreen.

        Then try it for real on the vault with `loam <command> …`; for a UI, `loam app relaunch` and
        `loam app shot`. Never test on the user's notes in a way that changes them without asking: make a test
        note, and remove it after.

        """
    }

    static var app: String {
        """
        # Drive the open app

        `loam app` talks to the Loam window that has this vault open (the vault from `--vault`, `LOAM_VAULT` or the
        current folder; without one, the last vault the app opened).

          loam app info                  the open vault, the note on screen, the app's plugins
          loam app list                  the window's commands: the plugins' UI ones and the shell's
                                         (sidebar.toggle-trailing, settings.plugins, workspace.split-right…),
                                         which `loam list` does not show
          loam app open <path>           opens a note (vault-relative) in the window
          loam app switch <folder>       makes the app open another vault (a folder; a new one is fine)
          loam app run <id> [key=value]  runs a command inside the app, UI commands included
          loam app shot <file.png>       a picture of the window: look at it to check a change
          loam app relaunch              restarts the app on the same vault: loads rebuilt plugins

        A panel in the `.trailing` slot shows in the right sidebar: `loam app run sidebar.toggle-trailing` opens it
        (`.leading`: the left one). Look before you click: there is no clicking from here, and no need for it.

        When nothing answers, the app is not running on that vault: ask the user to open it (`open -a Loam`).

        """
    }

    static var share: String {
        """
        # Share a plugin

        A plugin is a folder: push `.loam/plugins/<id>/` to a git repository (with its README saying what it does
        and the permissions it asks for). Anyone installs it with

          loam plugin install <git url>

        which clones it, checks plugin.json, builds it and leaves it off until the user enables it after reading its
        permissions (`loam plugin enable <id>`, or Settings > Plugins). `loam plugin remove <id>` moves it to the
        trash.

        # Release a new version

        Bump `version` in plugin.json, commit, then tag it: `git tag v1.2.0 && git push --tags`. Set `minSDK` in
        plugin.json (`loam guide` prints the app's plugin SDK) when the plugin needs a newer app. Installs take the
        highest tag; without tags they follow the default branch.

          loam plugin outdated          what has a newer version
          loam plugin update <id>       update and rebuild (--all for every plugin)
          loam plugin rollback <id>     back to the version the update replaced

        An update that asks for a new permission disables the plugin until the user enables it again.

        # The catalog

        `loam plugin catalog [query]` lists the public catalog; `loam plugin install --catalog <id>` installs from it,
        refusing any commit the catalog did not pin. To list a plugin, open a pull request on the catalog repository,
        https://github.com/Azilone/loam-community, adding its repo, tag and commit to index.json. The same repository
        lists community themes in themes.json: `loam app run themes.catalog`, then
        `loam app run themes.install id=<id>` and `loam app run themes.use name=<id>`.

        # Publish a theme

        A theme is one JSON file (format: docs/THEMES.md in the Loam repository; start from `.loam/themes/<Name>.json`).
        To list it, open a pull request on https://github.com/Azilone/loam-community with two changes:

        1. Add the file as `themes/<id>.json`. The id is lowercase letters, digits, `-` and `_`, 64 characters at most.
        2. Add its entry to `themes.json`:

        ```json
        { "id": "paper", "name": "Paper", "author": "you", "description": "…", "version": "1.0.0", "appearance": "auto" }
        ```

        `appearance` is `light`, `dark` or `auto`, as in the theme file. Check it before the pull request: put the
        repository's `themes.json` in `LOAM_THEME_CATALOG` and run `loam app run themes.install id=<id>`.

        """
    }
}
