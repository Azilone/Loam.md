---
name: plugin-dev
description: Create or modify a plugin for the Loam app (PluginKit, PluginKitUI). Use when adding a feature, a command, a service, an importer, or a view, panel or popup to the app, or when writing a third-party plugin that lives in a vault (`loam plugin`).
---

Everything in the app is a plugin. To add a brick, write a plugin; do not edit the core.

First decide which kind:

- **First-party**: part of this repository, shipped in the app. Steps 1 to 9 below.
- **Third-party**: lives in a user's vault (`.loam/plugins/<id>/`), built on their Mac against the app's SDK; the
  user asked for "my own plugin", "a plugin for my vault", or you are not changing this repository. Follow
  "Third-party plugins" at the end instead of steps 6 and 7.

1. Read `docs/VISION.md`, `docs/WRITING-PLUGINS.md` and `AGENTS.md`, then "Where new behaviour goes" below, and look at `Sources/Plugins/HabitTracker` and its tests, the worked example
   (`App/Sources/Plugins/QuickSwitcherUI` for a UI plugin).
2. Pick an id (`kebab-case`). Decide the services it `provides` and `requires`. A service is a protocol plus a
   `ServiceKey`; plugins never depend on each other directly.
3. Write the plugin: a `final class` conforming to `Plugin` with a static `manifest` and `activate(context:)`.
   Register commands, services and listeners only through the context so unloading undoes them. Every service id in
   `provides` must actually be provided in `activate`.
4. Work on plain Markdown files only: CommonMark + GFM + YAML frontmatter, standard relative links.
   Never invent a syntax or a file format.
5. Write XCTest tests that build a `Kernel` and a `PluginHost`, activate the plugin, exercise its commands, then
   `deactivateAll()` and check nothing is left registered.
6. Put it in `Sources/Plugins/<Name>/` and its tests in `Tests/Plugins/<Name>/`, add `<Name>` to `plugins` in
   `Package.swift` and `<Name>Plugin.self` to `Sources/BuiltinPlugins/BuiltinPlugins.swift`.
7. If it needs an interface, add a UI module too (`docs/WRITING-PLUGINS.md` section 7): a `UIPlugin` in
   `App/Sources/Plugins/<Name>UI/` that registers views, panels and commands through the context and reaches the
   shell only through `context.workspace`, `context.quickPick` and `context.editor`. It presents and calls the logic
   module; the logic stays in step 3. Test it in `App/Tests/Plugins/<Name>UITests/` with `UIPluginHarness`
   (`PluginKitUITesting`), add both targets to `App/Package.swift` and `<Name>Plugin.self` to
   `App/Sources/BuiltinUIPlugins/BuiltinUIPlugins.swift`.
8. Run `make test` and fix failures before finishing. To try the app: `scripts/agent-run.sh NAME` (AGENTS.md).
9. Say in your answer which services the plugin provides and requires, and which commands, views and panels it adds.

## Where new behaviour goes

| Goal | Mechanism |
|---|---|
| Add a feature a user triggers | `context.registerCommand`; it reaches the palette, the CLI and the AI tools |
| Offer a capability to other plugins | define a protocol and a `ServiceKey`, `context.provide` it, list its id in `provides` |
| Use another plugin's capability | `context.service(key)`, list the id in `requires` |
| Observe something happening | `context.on(Event.self)` |
| Wrap or veto something | `context.intercept(Event.self)` and `context.waterfall` |
| Undo something on unload | `context.effect { ... }` |
| Find notes by folder, tag or property | `context.service(.noteQuery)` (`run`, `values`, `setProperty`), `note-query` in `requires` |
| Show notes as a table, board or gallery | write a `.base` file (Obsidian Bases YAML) or use the `collection.*` commands; the `collections` service in code |
| Add a kind of collection view (calendar) | a `UIPlugin` calls `context.addCollectionView(CollectionViewType(...))`, `collections.views` in `optionalRequires` |
| Add an item to a file or folder's menu | a `UIPlugin` calls `context.addResourceAction(ResourceAction(...))` |
| List, check or add tasks (`- [ ]` lines) | the `tasks.*` commands; syntax in [docs/TASKS.md](../../../docs/TASKS.md) |
| Own a folder whose notes mean something (daily notes, habits) | intercept `ManagedFolders` and add it, emit `ManagedFoldersChanged` when the setting changes; new notes then go to the inbox instead, and the folder lists after the user's; place new items with `ManagedFolders.newItemFolder(from:)` |
| Read or create projects (notes of `Projects/`, their task notes and Kanban) | the `projects.*` commands, the `projects` service; rules in [docs/PROJECTS.md](../../../docs/PROJECTS.md) |
| Read or write notes | `context.vault` (`read`, `write`, `writeData`, `move`, `exists`, `markdownPaths`); read right before writing, and open editors stay in sync |
| Let users configure a plugin | `context.settings.value(default:)` in `activate`, `update`; its page in Settings shows every key; name them with `settings: [SettingDescription(..., default:)]` in the manifest (the default shows them before it runs) and re-read on `PluginSettingsChanged` |
| Give the plugin a face in Settings > Plugins | `description:` (one line) and `icon:` (an SF Symbol name) in its manifest; plugin.json can add `iconFile` |
| Show something in the workspace (a view type) | a `UIPlugin` calls `context.registerView(ViewType(...))`; open it with `context.workspace?.open` |
| Add a row to the sidebar's navigation (Tasks, Calendar) | a `UIPlugin` calls `context.addSidebarLink(SidebarLink(...))` with the resource to open |
| Add a sidebar or status bar panel | a `UIPlugin` calls `context.registerPanel(Panel(..., slot: .leading))` |
| Add options to the right sidebar | the view calls `viewContext.setInspector(viewType:tabs:)` in `onAppear`; any plugin adds groups with `context.addInspectorSection` (`.tab(InspectorPage)`, `.primary` or `.info`); draw them with the `Inspector…` bricks; nothing the page already shows, nothing empty |
| Lay out a page (title, width, empty state) | `PageScaffold(title, subtitle:, width:)` or `PageHeader` + `.pageColumn(.reading)`, `EmptyState`; text `.ui(.body)`, spacing `Space`, colours `theme`: [docs/UI-RULES.md](../../../docs/UI-RULES.md), never a size of your own |
| Put a band above some notes' text (the week above a daily note) | a `UIPlugin` calls `context.addNoteHeader(NoteHeader(...))`; the editor draws it |
| Offer a filterable popup list (like Cmd+O) | `context.quickPick?.show(placeholder:items:choose:)`, ranked with `Fuzzy.rank` |
| Let a row be dragged into the workspace | `.draggableResource(.file(path))` on the row's view |
| Give a feature a keyboard shortcut | `shortcut: KeyShortcut("n", [.command])` on its `Command`; `.loam/config.json` can override it |
| Add an item to the `/` menu | `context.addSlashItem(SlashItem(...))`, with `editor` in `optionalRequires` |
| Add a section to the `@` menu (Days) | `context.addMentionSource(MentionSource(...))`, with `editor` in `optionalRequires` |
| Draw a fenced code block as a picture (` ```mermaid `) | `context.addCodeBlockRenderer(CodeBlockRenderer(...))`, with `editor` in `optionalRequires` |
| Show image links to some file types in notes (a player, a preview) | `context.addEmbedRenderer(EmbedRenderer(...))`, with `editor` in `optionalRequires` |
| Take files dropped or pasted into a note | `context.addFileDropHandler(FileDropHandler(...))`; to store them, the `attachments` service (`importFile`) |
| Change attachments on their way into the vault (compress, convert) | `context.addAttachmentProcessor(AttachmentProcessor(...))`, with `attachments` in `optionalRequires`; later: `AttachmentImported`, then `replace` |
| A fenced block as a live view (` ```base `) | `context.addCodeBlockView(CodeBlockView(...))`, with `editor` in `optionalRequires`; the view reads `CodeBlockContext.code` and edits with `replaceCode` |
| Write a plugin outside the app, in a vault | `loam plugin new <id> [--ui]`, `loam plugin build <id>` ([docs/WRITING-PLUGINS.md](../../../docs/WRITING-PLUGINS.md) section 8) |

## Third-party plugins

Use the app's `loam` (`Loam.app/Contents/Helpers/loam`, or `App/build/Loam.app/Contents/Helpers/loam` after
`scripts/agent-run.sh`), on a test vault, never the user's real vault unless they ask. `docs/WRITING-PLUGINS.md` section 8 has the
details.

1. `loam --vault <vault> plugin new <id>` (add `--ui` for a panel or view). It writes a working package in
   `<vault>/.loam/plugins/<id>/`: `plugin.json`, `Package.swift`, `Sources/<Name>/<Name>Plugin.swift`, one test.
2. Edit the source with the same API as steps 2 to 5 above. Keep `Package.swift` linking only `LoamRuntime`
   (and `LoamUIRuntime`); declare what the plugin touches in `plugin.json` `permissions`; plugin type ids
   must equal the package id or start with it and a dot.
3. `loam --vault <vault> plugin build <id>`: read `ok` and `log` in its JSON, fix compile errors, repeat.
4. Optionally run its tests: `LOAM_SDK=<sdk> swift test` in the plugin folder, the SDK being the app's
   `Contents/Resources/SDK/loam` or a checkout of this repository.
5. `loam --vault <vault> plugin enable <id>` (or Settings > Plugins), then run its command with
   `loam --vault <vault> <command-id>`, or relaunch the app for its UI.
6. Say which commands, panels and permissions it has, and that on macOS it needs a rebuild (`loam plugin build`) only when the
   plugin SDK's major version changes.
