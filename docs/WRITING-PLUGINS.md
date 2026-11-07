# Writing a plugin

This guide is for people and for AI agents. A plugin is a small Swift class. It adds commands, offers services to
other plugins, and listens to events; a UI plugin (section 7) adds views and panels to the Mac app. Read
[VISION.md](VISION.md) for the spirit and [DESIGN.md](DESIGN.md) for the architecture. The agent skill that automates this guide is `.agents/skills/plugin-dev`.

The worked example is the habit tracker, `Sources/Plugins/HabitTracker` (about 440 lines, plus its tests in
`Tests/Plugins/HabitTracker`). Its UI module, the habits board, is `App/Sources/Plugins/HabitsUI`.

## 1. The shape of a plugin

```swift
import PluginKit

public final class HabitTrackerPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(id: "habit-tracker", name: "Habit tracker", version: "0.1.0")
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        try context.registerCommand(Command(
            id: "habits.check",
            title: "Check in a habit",
            summary: "Records a day for a habit. Arguments: name; optional: date (YYYY-MM-DD)."
        ) { arguments in
            // arguments is [String: String]; return text, usually JSON
        })
    }
}
```

- `manifest.id` is unique and `kebab-case`. `provides` and `requires` list service ids (see section 3).
- `description` (one line) and `icon` (an SF Symbol name, `"flame"`) are what Settings > Plugins shows on the
  plugin's row and page; without an icon it gets the default one.
- Everything registered through `context` is undone when the plugin unloads. Never clean up by hand, never keep
  global state.
- A command's `summary` is what the CLI (`loam list`) and the AI assistant show, so write it for an agent: say what
  it does and name its arguments.
- `shortcut: KeyShortcut("up", [.command])` gives it a default key, which `.loam/config.json` can change and the
  palette shows. A key that belongs to one view (the mindmap's ⌘↑ moves a topic, but ⌘↑ in a note moves the caret)
  adds `isShortcutEnabled: { store.keyboardTab != nil }`: when it says no, the shell leaves the key to the focused
  view. The palette, the CLI and agents run the command whatever it says. A key without ⌘ or ⌃ that the view
  handles itself (the mindmap's Tab adds a child) goes in `viewKey` instead: the palette shows it next to the
  command, and it cannot be changed.

### Settings

A plugin's options are one `Codable` value with a default, read with `context.settings.value(default:)` and saved with
`context.settings.update(_:)`; they live in `.loam/config.json` under `plugins.<id>.settings`. The plugin's page in
Settings > Plugins shows every key of that value with its current value, without any UI code: a switch for a bool, a
field for a string or a number, read-only JSON for a list or an object. The kernel learns the keys and their defaults
when the plugin reads its settings (usually in `activate`), so read them there.

Name them in the manifest for a nicer page; a key without a description is titled after itself (`showRecent`: "Show
recent"). Give a description its `default:` too (the same value as the `Codable` default) and the page shows the
setting before the plugin has run, turned off or in safe mode:

```swift
struct Settings: Codable, Equatable { var folder = "Habits"; var week = "monday" }

PluginManifest(id: "habit-tracker", name: "Habit tracker", version: "0.1.0", settings: [
    SettingDescription("folder", title: "Folder", help: "Where habit notes go.", default: .string("Habits")),
    SettingDescription("week", title: "Week starts on", choices: [
        SettingChoice(.string("monday"), title: "Monday"), SettingChoice(.string("sunday"), title: "Sunday"),
    ]),
])
```

A change made on the page, or by an agent with `plugins.set-setting id=<id> key=<key> value=<JSON>` (`plugins.settings
id=<id>` lists them), sends `PluginSettingsChanged` with the plugin's id: listen to it and read the settings again, so
the change applies at once (`DailyNotesPlugin` and `HabitTrackerPlugin` do). A value the plugin cannot read is refused
and nothing is written: another type than the default (text for a switch), or a fraction where it reads an `Int`. One
key of the wrong type written by hand in `config.json` follows its default; the other keys are kept. A key the plugin never
reads is refused too, and one found in `config.json` is not shown on its page. A change made from another process (the CLI,
a sync) is announced the same way once the app sees the file change. A service that others draw from (`habits`,
`daily-notes`) sends its own event (`HabitsFolderChanged`, `DailyNotesLayoutChanged`) after it applied new settings.

## 2. Data lives in plain Markdown

A plugin reads and writes the vault only through `context.vault` (`read`, `write`, `move`, `exists`,
`markdownPaths`). Paths are relative to the vault and cannot leave it. Store data in files a person can read and
edit: CommonMark and GFM, YAML frontmatter for properties, standard relative links. Never invent a syntax or a
file format. The habit tracker keeps one task-list line per day in `Habits/<name>.md` (the folder is a setting), and
leaves the rest of the note alone.

Write through `context.vault` and read the note right before you edit it, never from an earlier copy: the editor
keeps open notes in sync. Your read makes it save the user's unsaved typing first, and your write makes it reload the
note, so neither your change nor their typing is lost (`NoteWillRead` / `NoteDidChange` in
[ARCHITECTURE.md](ARCHITECTURE.md)). Never hold a lock while reading: the read may wait for the main thread.

## 3. Services: how plugins use each other

Plugins never depend on each other directly. A plugin that offers a capability defines a protocol and a key:

```swift
public protocol NoteGraphService: AnyObject { /* ... */ }

public extension ServiceKey where Service == NoteGraphService {
    static var noteGraph: ServiceKey<NoteGraphService> { ServiceKey<NoteGraphService>("note-graph") }
}
```

It lists `"note-graph"` in `provides` and calls `try context.provide(.noteGraph, implementation)` in `activate`.
A plugin that needs it lists `"note-graph"` in `requires` and calls `context.service(.noteGraph)`. The host
activates providers first, reports a missing service or a cycle, and refuses two providers of the same service,
so any plugin can be replaced by another that provides the same service.

## 4. Events

`context.on(Event.self) { ... }` observes. `context.intercept(Event.self) { event, next in ... }` wraps or vetoes:
call `next(event)` to continue, return without it to stop. `context.emit` and `context.waterfall` send events.
Events are plain structs conforming to `PluginEvent`.

## 5. Test it

Build a `Kernel` over a temporary folder, register the plugin in a `PluginHost`, run the commands, then check the
files. See `Tests/Plugins/HabitTracker`. Finish with `host.deactivateAll()` and check nothing is left registered.

```bash
make test
```

## 6. Register it and run it from the CLI

A first-party plugin is three small steps:

1. Put it in `Sources/Plugins/<Name>/` (class `<Name>Plugin`) with tests in `Tests/Plugins/<Name>/`.
2. Add `<Name>` to the `plugins` list at the top of `Package.swift`.
3. Add `<Name>Plugin.self` to `Sources/BuiltinPlugins/BuiltinPlugins.swift`.

`make test` then also checks that the plugin activates alone and with all the others, and that its commands have a
useful summary. Every registered command is available in the CLI:

```bash
loam --vault ~/Notes list
loam --vault ~/Notes habits.check name=Meditate
loam --vault ~/Notes daily.append text="Met Bob"
```

Commands print their result on stdout. Errors go to stderr as JSON with a non-zero exit code.

## 7. UI plugins

Every view follows [UI-RULES.md](UI-RULES.md): a page is a `PageScaffold` (or `PageHeader` + `.pageColumn`), text
is on the type scale (`.font(.ui(.body))`), spacing on `Space`, colours from `theme`. The app's pages use the same
pieces, so a plugin looks like the app without measuring anything.

A feature with an interface is up to **two modules**:

- the **logic** module, `Sources/Plugins/<Name>` in the root package: data, services and commands, Foundation
  only, so the CLI and agents can do everything without a window;
- the **UI** module, `App/Sources/Plugins/<Name>UI` in the `App/` package: views, panels and popups that present
  the logic and call its commands and services. It imports its own logic module, `PluginKit` and `PluginKitUI`,
  never another plugin and never the shell.

A UI plugin conforms to `UIPlugin`, whose `activateUI(context:)` runs on the main actor. It registers view types
(what opens in a tab), panels (what sits in a sidebar or the status bar) and commands through the context, and
reaches the shell only through contracts: `context.workspace` to open a resource, `context.quickPick` for a popup
list, `context.editor` for the Markdown editor. Every registration is undone when the plugin unloads.

```swift
import PluginKitUI
import SwiftUI

public final class TipsPlugin: UIPlugin {
    public static let manifest = PluginManifest(id: "tips", name: "Tips", version: "0.1.0")

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        let tips = Tips(context: context)
        // A view type: which resources it opens, and the view for them.
        try context.registerView(ViewType(
            id: "tips.page",
            title: "Tips",
            canOpen: { $0 == Tips.page },
            makeView: { _ in AnyView(Text("Tip: drag a note onto the edge of a pane to split it.")) }
        ))
        // A panel in the left sidebar, whose button opens the page beside the current tab.
        try context.registerPanel(Panel(id: "tips.panel", title: "Tips", symbol: "lightbulb", slot: .leading) {
            AnyView(Button("Open tips") { _ = tips.open() })
        })
        // The same action as a command, so the palette, the CLI and agents reach it too.
        try context.registerCommand(Command(
            id: "tips.open",
            title: "Open tips",
            summary: "Opens the tips page beside the current tab. Returns what it did."
        ) { _ in
            await MainActor.run { tips.open() }
        })
    }
}

/// The plugin's main-actor state. Closures given to the context capture this, not the context.
@MainActor
final class Tips {
    static let page = Resource.virtual("tips:")
    private let context: PluginContext

    init(context: PluginContext) { self.context = context }

    func open() -> String {
        guard let workspace = context.workspace else { return "No workspace in this host." }
        workspace.open(Self.page, placement: .beside)
        return "Opened the tips."
    }
}
```

The real examples are the file explorer (`App/Sources/Plugins/FileExplorerUI`, on its logic module
`Sources/Plugins/FileExplorer`) and the quick switcher (`App/Sources/Plugins/QuickSwitcherUI`).

Test it with `UIPluginHarness` (`PluginKitUITesting`): a kernel on a temporary vault with the host services in place,
a recording workspace and quick pick, and `render(_:)` to lay a view out offscreen.

```swift
import PluginKitUITesting
import XCTest
@testable import TipsUI

@MainActor
final class TipsUITests: XCTestCase {
    func testTheCommandOpensTheTipsPageBeside() async throws {
        let harness = try UIPluginHarness(uiPlugins: [TipsPlugin.self], files: ["Note.md": "# Note\n"])
        defer { harness.close() }
        XCTAssertEqual(harness.views.viewTypes(for: Tips.page).map(\.id), ["tips.page"])
        XCTAssertEqual(harness.panels.panels(in: .leading).map(\.id), ["tips.panel"])

        _ = try await harness.run("tips.open")
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [Tips.page])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.beside])
    }
}
```

To ship it: add a target `<Name>UI` (`path: "Sources/Plugins/<Name>UI"`) and its test target to `App/Package.swift`,
then add `<Name>Plugin.self` to `App/Sources/BuiltinUIPlugins/BuiltinUIPlugins.swift`. `BuiltinUIPluginsTests`
then checks it activates alone and with the others, renders its views and panels, and unloads cleanly. Run it in
the app on a demo vault: `make test-vault` (once), then `make run`.

### Inside notes

A plugin reaches into the open note only through the `editor` service, with `editor` in `optionalRequires`:
`context.addSlashItem` (the `/` menu), `context.addCodeBlockRenderer` (a fenced block as a picture, as `DiagramsUI`
draws ` ```mermaid `), `context.addEmbedRenderer` (an image link alone on its line, `![](assets/clip.mp4)`, as a
picture or a player, as `AttachmentsUI` does) and `context.addFileDropHandler` (files dropped or pasted into a note).
Files go into the vault through the `attachments` service; a plugin that compresses or converts them adds an
`AttachmentProcessor` (ARCHITECTURE.md, "Attachments"); the first-party `Squeeze` plugin is the worked example, and
"Media compression" there says how a logic plugin asks the app for something Foundation cannot do (PDFKit) through a
service. `context.toasts?.show(_:isError:)` tells the user about work that ends on its own. The note stays plain
Markdown: these only change what is shown, or insert standard links.

### 7.1 A kind of collection view

Collections (`.base` files, see DESIGN.md) are drawn by view plugins: Table, Kanban and Gallery are three of them.
A new kind, a calendar say, is a `UIPlugin` that adds a `CollectionViewType` whose `id` is the `type:` it draws:

```swift
context.addCollectionView(CollectionViewType(id: "calendar", title: "Calendar", symbol: "calendar") { model in
    AnyView(CalendarView(model: model))   // model.entries, model.value(ref, of:), model.set(ref, to:, on:)
})
```

List `collections.views` in `optionalRequires`. The view reads `model.entries` (or `model.groups` with
`groupsEntries: true`), the shown `model.fields` and their `model.kind(ref)`, and acts through the model
(`set`, `newEntry`, `edit`, `open`), so every change is a frontmatter line or a `.base` edit. Its own settings go in
the view's other keys (`.setViewOption`), which Loam keeps.

## 8. Third-party plugins: `loam plugin`

Sections 1 to 7 describe first-party plugins, compiled into the app. Anyone can also write a plugin that lives in a
vault, in `.loam/plugins/<id>/`, and is compiled on the user's Mac against the app's SDK
([PLUGIN-LOADING.md](PLUGIN-LOADING.md)). The API is the same; only the packaging differs. Use the app's own `loam`
(`Loam.app/Contents/Helpers/loam`; `ln -s` it onto the PATH), so the plugin matches the app's runtime.

```bash
loam --vault ~/TestVault plugin new word-count          # logic: a command; builds on Linux too
loam --vault ~/TestVault plugin new word-panel --ui     # UI: a panel and a command (macOS 26)
# edit ~/TestVault/.loam/plugins/word-count/Sources/WordCount/WordCountPlugin.swift
loam --vault ~/TestVault plugin build word-count        # {"ok": true, "library": ..., "log": ...}
loam --vault ~/TestVault plugin enable word-count       # or Settings > Plugins, after reading its permissions
loam --vault ~/TestVault word-count.hello
```

- **The package.** `plugin.json` (`id` = folder name, `library` = the dynamic product, `permissions` shown before
  enabling; optional `description`, `icon` (an SF Symbol name) and `iconFile` (an image in the plugin's folder, shown
  instead of the symbol), which Settings > Plugins shows before the code is ever loaded), `Package.swift`, `Sources/<Name>/<Name>Plugin.swift`, one test, a README. The manifest reads the SDK's
  path from `LOAM_SDK` (`loam plugin build` sets it) and links only `LoamRuntime` (and `LoamUIRuntime`
  for a UI plugin): never another product of the SDK, or the process would hold two copies of PluginKit.
- **Ids.** Every plugin type the entry returns has the package's id or starts with it and a dot (`word-count.extra`).
- **The entry point.** `@_cdecl("loam_plugin_entry")` returns `PluginEntry(plugins: [...])`, which records
  the plugin SDK version it is built against. On macOS the plugin keeps running after app updates that only add to
  the SDK; it needs a rebuild only when the SDK's major version changes (on Linux, after every app update).
- **Only the SDK.** Import `PluginKit` and `PluginKitUI`, nothing else from Loam: the kernel, the shell, the editor
  and first-party plugins change with every release, and `loam plugin build` refuses a plugin that uses them. Switch
  over an SDK enum with `@unknown default`: a later release may add cases.
- **Iterating.** Rebuild, then `loam app relaunch` (or relaunch the app): a loaded library is not reloaded. `loam`
  loads it fresh on every run. `loam app shot <png>` shows the window, to check a UI.
- **Tests.** `loam plugin test <id>`, or in the plugin's folder `LOAM_SDK=<the SDK> swift test` (the SDK is the
  app's `Contents/Resources/SDK/loam`, or a checkout of this repository).
- **Agents.** `loam guide plugins` is this section for an outside agent, and the "loam" skill
  ([DEVELOPERS.md](DEVELOPERS.md)) tells Claude Code, Codex and the others to read it.
- **Sharing.** Push the folder to a git repository; others run `loam plugin install <git url>`, which clones it, checks
  plugin.json, builds it and leaves it off until they enable it. `loam plugin remove <id>` moves it to `.trash/plugins/`.

## Checklist

- [ ] Plugin id is unique; `provides` matches what `activate` provides.
- [ ] Commands have an agent-friendly `summary`.
- [ ] Data is plain Markdown, written only through `context.vault`.
- [ ] No global state; everything registered through `context`.
- [ ] Tests cover the commands and the unloading.
- [ ] Added to `plugins` in `Package.swift` and to `BuiltinPlugins.swift`.
- [ ] A UI module, if any, only presents and calls the logic module's commands and services, and is listed in
  `BuiltinUIPlugins.swift`.
- [ ] Its views follow [UI-RULES.md](UI-RULES.md): `PageScaffold` / `PageHeader`, `.ui(.…)`, `Space`, `theme`, `EmptyState`.
