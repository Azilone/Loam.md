# Architecture

How "everything is a plugin" stays clean as the app grows. Read [VISION.md](VISION.md) and [DESIGN.md](DESIGN.md)
first. When a change does not fit the rules below, change this file first, in its own pull request, then the code.
Nothing here is final: if a rule turns out wrong, we rewrite it and rebuild, but we never work around it quietly.

## The one rule

**A plugin depends on contracts, never on another plugin and never on the shell.**

A contract is a protocol in `PluginKit` or `PluginKitUI`, reached through the plugin's context. Who implements it
(a plugin, the shell, a fake in a test) is invisible to the caller.

Example: a Kanban plugin wants to show a board next to the current note. It calls
`workspace.open(board, placement: .beside)`. It does not know that tabs or splits exist. The Mac shell opens a
split, an iPhone shell pushes a screen, the test workspace records the call. Tabs can be rewritten from scratch
without touching the Kanban plugin. This is what keeps dependencies from tangling as the number of plugins grows.

## Layers

```
Vault format          plain files: the only contract that is permanent
PluginKit             logic contracts: plugin, context, commands, services, events, vault       Foundation, Linux
LoamCore              the kernel: plugin host, registries, event bus, vault                     Foundation, Linux
PluginKitUI           UI contracts: resources, views, workspace, panels, settings, theme         SwiftUI, macOS + iOS
Shell (App/)          implements the UI contracts: window, workspace, slots, palette, settings
Plugins               essential ones (enabled by default) and bricks
```

`Runtime` (in `LoamCore`) is one open vault: kernel, plugin host and `.loam/config.json` wired together, used
by the CLI and tests, so which plugins run is always decided by the vault's config.

| Module | May import |
|---|---|
| a plugin's logic module | `PluginKit`, Foundation |
| a plugin's UI module | its own logic module, `PluginKit`, `PluginKitUI`, SwiftUI and system frameworks |
| `PluginKitUI` | `PluginKit`, SwiftUI |
| the shell (`NotebookApp`) | `PluginKit`, `PluginKitUI`, `WorkspaceModel` and the kernel; never a plugin |
| the executable (`Loam`) | the shell and the plugin lists, `BuiltinPlugins` and `BuiltinUIPlugins` |
| never | a plugin importing another plugin, the kernel, or the shell |

`Package.swift` enforces the table for the root package: each target lists only the modules it may import. In
`App/`, every target depends on the one runtime product (below), which carries all the logic modules, so the table
holds there by review. The executable hands the shell its plugins in a `ShellConfiguration`, so the shell never
names one.

## Runtime libraries

Third-party plugins are loaded into the process at run time and must share the app's types: a second copy of
PluginKit would make every service lookup fail. So each shared module lives in exactly one dynamic library
([PLUGIN-LOADING.md](PLUGIN-LOADING.md)):

| Library | Package | Holds |
|---|---|---|
| `LoamRuntime` | root (its only product) | PluginKit, the kernel, `PluginKitTesting`, the CLI logic, every logic plugin |
| `LoamUIRuntime` | `App/` (its only product) | PluginKitUI, `PluginKitUITesting`, the editor, `WorkspaceModel`, the shell, every UI plugin |

The executables only hold `main.swift` and live in their own packages, because SwiftPM links an executable with its
own package's targets statically: `CLI/` (`loam`) and `App/Executable/` (the app). The bundle ships both libraries in
`Contents/Frameworks`; `scripts/check-single-copy.sh` fails the build if a type is defined twice. `PluginKit` and
`PluginKitUI` are built with library evolution, so a plugin keeps running across releases that only add API: the
loader checks its `PluginSDKVersion` (on Linux, the exact runtime `PluginRuntime.buildID`), and `make test` checks, on macOS,
that the SDK only grows (`scripts/check-plugin-api.sh`, baseline in `api/`). See PLUGIN-LOADING.md.

## A brick is up to two modules

| Part | Package | Builds on | Holds |
|---|---|---|---|
| Logic, `<Name>` | root package, `Sources/Plugins/<Name>` | Linux and macOS | data in Markdown, services, commands |
| UI, `<Name>UI` (optional) | `App/`, `App/Sources/Plugins/<Name>UI` | macOS | views, panels, slash items |

The logic part works without any interface: the `loam` command line and AI agents use it through its commands. The UI
part only presents and calls the same commands and services. This is how "whatever you can do, your agent can do" is
kept by construction: a feature with no command behind its button is a bug.

`Sources/BuiltinPlugins` lists the logic plugins (CLI and app). `App/Sources/BuiltinUIPlugins` lists the UI plugins
(app only).

## Core or plugin?

Something goes in the shell only if it hosts plugins or rescues the user from them:

- the window and the **workspace**: tabs, splits, drag and drop, saving the layout;
- the **slots** plugins fill: left sidebar and status bar; the right sidebar is the **inspector** of the focused tab;
- the **command palette** (Cmd+P), the interface of the command registry;
- the **settings window** and the plugin manager (enable, disable, configure);
- **safe mode**.

Everything else is a plugin. The essential ones ship enabled and can each be replaced by another plugin that
provides the same service, or turned off while the shell keeps working (`EssentialPluginsTests`):

| Essential plugin | Modules | Provides | Status |
|---|---|---|---|
| Markdown editor | `MarkdownEditorUI` (on `MarkdownEditor`) | the view for `.md` files, the `editor` service (slash items, insert at caret, live text, reveal a line), `DocumentTextChanged` | done |
| File explorer | `FileExplorer` + `FileExplorerUI` | the Files panel: folder tree with recent notes on top; create, rename, move, trash; `explorer.new-note` opens an unwritten draft in the focused tab and `explorer.new-note-in-tab` (Cmd+N, File > New Note) in a new tab: the file appears with the first text and goes again when the note is emptied (never a note that was on disk before the session); `files.new-note` is the scripting command and does write the file | done |
| Quick switcher | `QuickSwitcherUI` | `switcher.open` (Cmd+O): open or create a note by name | done |
| Search | `TruffleSearch` + `SearchUI` | the `search` service and the Search panel: names, content and meaning, results grouped by note; `search.focus` (Shift+Cmd+F) as a popup | done: Truffle when it runs, else a built-in scan for names and content (meaning needs Truffle) |
| Backlinks | `BacklinksUI` (on the `note-graph` service) | a note's "Links" tab (right sidebar): the notes linking to the open note with the lines where they do, and its unlinked mentions; `backlinks.mentions` | done |
| Note info | `NoteInfoUI` (on `note-graph`, `note-query`, optionally `tasks` and `editor`) | a note's "Stats" tab (right sidebar): words, characters, reading time and tasks as large figures, then modified and created; `note-info.show` also gives the properties, backlinks and boards (words, characters, tasks, reading time) | done |
| Calendar (daily notes) | `DailyNotes` + `DailyNotesUI` | `daily.open-today` (Cmd+D), previous and next daily note; the calendar view (`calendar:` and `calendar:YYYY-MM`) and the calendar of a daily note's "Day" tab (right sidebar); a note header above every daily note (week strip, date); a day opens as a draft, its file written when text is added; a date pill in a note opens that day (Cmd: new tab, Option: select the pill), and `TasksUI` adds the tasks due that day | done |

Without the editor a `.md` tab shows the shell's placeholder; without the explorer there is no Files panel and File >
New Note is disabled; without the switcher Cmd+O does nothing; without the
Search panel the `search.*` commands still work.

## Contracts

Everything a plugin registers goes through its context and is undone when it unloads (the existing `Scope`).

**Host services.** The shell is not a plugin. Before any plugin activates, it provides its UI registries and
services straight into the kernel's service registry, and removes them after the plugins unload. A requirement
already provided this way counts as met when the host orders plugins. Tests do the same with fakes.

| Host service | In the app | In tests (`UIPluginHarness`) |
|---|---|---|
| `ui.views` | `ViewRegistryStore` | `ViewRegistryStore` |
| `ui.panels` | `PanelRegistryStore` | `PanelRegistryStore` |
| `ui.workspace` | `WorkspaceController` (tabs and splits) | `RecordingWorkspace` |
| `ui.quick-pick` | `QuickPickController` (the popup of the palette and Cmd+O) | `RecordingQuickPick` |
| `ui.toasts` | `ToastBridge`, into the `CommandRunner`'s toast | `RecordingToasts` |
| `ui.commands` | `CommandBridge`, into the `CommandRunner` | `RecordingCommands` |
| `ui.resource-actions` | `ResourceActionStore` (protocol `ResourceActionRegistry`; row menus of the Files panel and the folder page) | `ResourceActionStore` |

The shell also registers its own commands under the owner "shell": `workspace.*` (new tab on Cmd+T: a "New Tab" on the home page with Quick Open ready, discarded if left untouched; close, next and previous tab,
split right and down), `sidebar.toggle-leading` / `-trailing` and `palette.open`. The `Runtime` adds
`plugins.list`, `plugins.enable`, `plugins.disable`, `plugins.settings` and `plugins.set-setting`. `PluginKitUI`
adds helpers on `PluginContext` such as `context.registerView(...)` that find the registry and register the undo, so
a plugin never cleans up by hand.
UI plugins conform to `UIPlugin`, whose activation runs on the main actor.

| Contract | Layer | What a plugin does with it |
|---|---|---|
| `Command` | PluginKit | registers an action, with an optional default shortcut, overridable in `.loam/config.json`; `isShortcutEnabled` scopes the shortcut to a view (the mindmap's ⌘↑ while a map has the keyboard), the palette, CLI and agents run the command whatever it says; `viewKey` names a key without ⌘ or ⌃ that the command's own view handles (the mindmap's Tab), which the palette shows and nothing can rebind |
| `KeyShortcut` | PluginKit | a key with modifiers, parsed from and printed as `shift+cmd+o`; the shell turns it into a key equivalent |
| `PluginPermission`, `DeclaredPermission` | PluginKit | declares what the plugin does (`vault.write`, `network`, `shell`…) in `permissions:` of its manifest or plugin.json; the plugin manager shows them before a plugin from the vault is enabled. Declared and shown, not enforced: plugins run in-process with the app's access ([PERMISSIONS.md](PERMISSIONS.md)) |
| `Service` | PluginKit | offers or uses a capability by id; `requires` and `optionalRequires` |
| `Event` | PluginKit | observes (`on`) or wraps (`intercept`, `waterfall`) |
| `VaultAccess` | PluginKit | reads, writes and moves files inside the vault; `list` (one folder) and `createFolder` and `removeIfEmpty` (deletes a note only when it holds nothing); `markdownPaths` lists the notes, `stamps` fingerprints every file (notes and any other) |
| `PluginManifest` | PluginKit | says what the plugin is: id, name, version, a one-line `description` and an `icon` (an SF Symbol name), shown in Settings > Plugins (`plugins.list` returns them); a plugin.json may add an `iconFile` in the plugin's folder. Without an icon the plugin gets the default one |
| `ToolLocating` (`tools`), `Plugin.requiresTools`, `Plugin.optionalTools` | PluginKit (the host provides the locator, `LoamCore/ToolLocator`) | programs a plugin runs (`git`, `ffmpeg`) are found by one lookup: `context.service(ServiceKey<ToolLocating>.tools)?.locate("git")`. A plugin static `requiresTools` that is missing keeps it from starting (it shows as skipped, with the names); `tools.install` takes the next step (`ToolInstaller`: Apple's developer tools installer, `brew install`, or Homebrew itself through the bundled `install-dependencies.command`), and the app's `ToolSetup` offers it once at launch, then looks again on its own (`tools.check`) until the waiting plugins start. `optionalTools` only tell the user what a feature needs |
| `VaultChanged` | PluginKit, sent by the kernel | files appeared, changed or disappeared on disk: every non-hidden file, not only notes, so a plugin owning a file type (`.canvas`) follows its files. A listener about notes only keeps `noteChanges`. See "Files other than notes" |
| `PluginSettings`, `SettingDescription` | PluginKit | reads a `Codable` settings value with `context.settings.value(default:)` and saves it with `update`; stored in `.loam/config.json` under its id, `PluginSettingsChanged` follows. The kernel keeps the default each plugin reads with (`Kernel.settingsDefault(for:)`), so the plugin's page in Settings shows every key, stored or not, with no UI code; `settings:` in the manifest gives them titles, help, a picker's choices and optionally the default (shown before the plugin runs). A value of another type than the default, or one the settings type refuses, is not written (`RuntimeError.invalidSetting`) |
| `NoteQuery`, `NoteQueryService` (`note-query`) | PluginKit, provided by the `NoteQuery` plugin | finds notes by folder, tag and property filters (`exists`, `missing`, `equals`, `notEquals`, `contains`, `lessThan`, `greaterThan`), sorted (missing values last) and limited, as `NoteRecord`s; `values(of:in:)` lists a property's distinct values; `setProperty` edits one frontmatter line and leaves the rest of the file as it was. The base of tasks, Kanban and other views over notes |
| `AttachmentsService` (`attachments`), `AttachmentImport`, `AttachmentProcessor` | PluginKit, provided by the `Attachments` plugin | copies a file into the one attachments folder (`assets`, set in its settings) under a free name and returns its link (`importFile`, `markdownLink`); a processor changes files on their way in (`context.addAttachmentProcessor`); `replace` puts a new version in place later. See "Attachments" below |
| `AttachmentImported`, `AttachmentReplaced` | PluginKit, sent by the Attachments plugin | on the main thread, after a file was written into the folder, or replaced |
| `HiddenFolders`, `HiddenFoldersChanged` | PluginKit | a file browser asks, as a waterfall, which folders to leave out of its tree (the attachments folder, when its settings hide it); the files stay on disk and in every other listing. `HiddenFoldersChanged` makes it list again |
| `ManagedFolders`, `ManagedFoldersChanged` | PluginKit | a file browser asks, as a waterfall, which folders plugins own (Daily, Habits, Projects, Meetings, attachments): it lists them after the user's folders and never drops a new, unrelated note in one (`newItemFolder(from:)`: the open folder, else the inbox). `ManagedFoldersChanged` makes it ask again |
| `CaptureStore` (`capture`), `CaptureContent`, `CaptureOutcome` | `CapturePlugin` (logic), used by `CaptureUI` | saves captures as notes in one collection, recognises exact duplicates, fills in link metadata; the window, the shortcut from any app (Carbon), the menu-bar icon and the agent turn are `CaptureUI`'s own AppKit. See [CAPTURE.md](CAPTURE.md) |
| `MediaCompressionService` (`media-compression`), `MediaOptimization`, `MediaBatchReport`, `MediaCandidate` | PluginKit, provided by the `Squeeze` plugin | shrinks images, sounds, videos and PDFs in the vault: `candidates`, `keepsOriginals`, `optimize(path)`, `optimizeVault()`. See "Media compression" below |
| `PDFRasterizing` (`pdf-rasterizer`) | PluginKit, provided by `SqueezeUI` | turns a PDF into one made of JPEG pages (`rasterize(_:to:dpi:jpegQuality:)`); PDFKit lives in the app, so the Foundation-only compressor asks for it through this service |
| `MediaOptimized`, `MediaOptimizationStarted`, `MediaOptimizationFailed`, `MediaBatchProgress` | PluginKit, sent by the Squeeze plugin | on the main thread: a file that just arrived was made smaller, a video or PDF started, a conversion failed (a missing tool is said once), a vault-wide run moved on |
| `ExcalidrawService` (`excalidraw`) | `ExcalidrawPlugin` (logic), used by `ExcalidrawUI` | reads and writes drawings (`.excalidraw.md`, `.excalidraw`): `scene` gives the editor its JSON with the images' bytes, `save` takes the editor's JSON back and stores new images in `assets/`; `isDrawing` is cached. See [EXCALIDRAW.md](EXCALIDRAW.md) |
| `NoteBoardsService` (`note-boards`) | PluginKit, provided by the `Canvas` plugin | the boards (`.canvas` files) with a card showing a note; Note Info and Backlinks list them as "On boards" (optional) |
| `CollectionService` (`collections`), `CollectionDefinition`, `CollectionSource`, `CollectionEdit` | PluginKit, provided by the `Collections` plugin | reads a collection (a `.base` file, or the YAML of a ` ```base ` block) and runs one of its views over the notes: entries, groups for a board, field kinds; `apply` edits the views and fields and keeps the keys it does not know; `create(folder:)` turns a folder into a collection; `adopt` moves a `.base` kept apart from its notes (Obsidian's) into the folder it shows; `newEntry` writes a note that matches the collection's filter. A collection is a folder: the sidebar opens it on click, "New → Collection" makes one, a note shows one by embedding its `.base` (`![](Ideas/Ideas.base)`, offered in `/`) |
| `FrontmatterEditor`, `PropertyComparison` | PluginKit | helpers: set or remove one frontmatter key keeping the rest of the file; the comparison and sort rules of property values |
| `NotesWillMove`, `NotesMoved` | PluginKit | sent around a move or rename: save pending edits before, follow new paths after |
| `NoteWillRead`, `NoteWillChange`, `NoteDidChange` | PluginKit, sent by `context.vault` | a plugin's `context.vault` sends them with the note's normalized path and the plugin's id: before a `read`; before a `write`, `writeData` or `move` (for a move, the source and the destination); and after that write succeeded. Listings, `exists`, `stamps`, `createFolder` and the kernel's own vault send nothing. Sent on the thread that reads or writes, so listeners that touch the UI hop to the main thread. See "Writes and open editors" |
| `UIPlugin` | PluginKitUI | a `Plugin` whose `activateUI(context:)` (and optional `deactivateUI()`) runs on the main actor |
| `Resource`, `Placement` | PluginKitUI | names what a view shows: a file, a folder, or a virtual page (`calendar:2026-10`) |
| `ViewType` | PluginKitUI | says which resources it can open (`canOpen`), with a `priority`, and builds the SwiftUI view; a page that shows many views or moves gives its AppKit view instead (`makeNSView`, shown by the shell without a hosting view; its `makeView` is then that same view in `NativeView`, never a second implementation). `CollectionViewType.makeNSView` does the same for a collection's views. An AppKit view follows the host's theme and toolbar room, and its height when embedded, through `NativeHostedView`, and an `@Observable` model through `Follow` |
| `ViewContext`, `ViewPresentation` | PluginKitUI | what a tab gives its view: the resource, `isActive`, a small `Codable` state (`state`, `setState`) and its `presentation`: `.page` for a tab, `.embedded` inside another view (a card on a board), where the view drops its page chrome, does not take the keyboard by itself and takes clicks only while `isActive`; an embedded view that draws its content at its own size (a mindmap, `ViewType.sizesToContent`) says where it is in `contentBounds`, and a board sizes its card to it |
| `Workspace` (`ui.workspace`) | PluginKitUI | opens a resource with a placement hint (`.replace`, `.newTab`, `.beside`); reports the active one; the shell sends `ActiveResourceChanged` |
| `InspectorTab`, `InspectorPage`, `InspectorSection`, `InspectorRegistry` (`ui.inspector`) | PluginKitUI | the right sidebar follows the focused tab, as Bear's and Craft's: the view publishes its own tabs with `viewContext.setInspector(viewType:tabs:)` (a mindmap's "Style", a graph's "Graph", a collection's "View", a board's "Board"), and plugins add groups with `context.addInspectorSection`: in a tab of their own (`.tab(InspectorPage)`, as a note's Outline, Links, Stats and Insert, a daily note's Day; the view's tabs count as order 0), under the view's first tab (`.primary`) or in "Info" (last); `viewTypes` limits a section to some views. One tab does one job and shows nothing the page already shows, nothing empty, no count nobody needs. Everything is drawn with the bricks of `InspectorKit.swift` (`InspectorGroup`, `InspectorCard`, `InspectorRow`, `InspectorTile`, `InspectorFigure`, `InspectorSegmented`, `InspectorSwatches`, `InspectorToggleRow`, `InspectorBarRow`) |
| `WindowOverlay`, `WindowOverlayRegistry` (`ui.window-overlays`) | PluginKitUI | a view a plugin floats over the workspace window in a corner (the Assistant's bubble and panel, bottom right), inside the window, above the pages and sidebars, below the palette and toasts; `context.addWindowOverlay`, removed on unload. The view sizes and animates itself; the shell only places it |
| `SettingsSection`, `SettingsSectionRegistry` (`ui.settings-sections`) | PluginKitUI | what a plugin's page in Settings shows under its generic settings when a form is not enough (the Assistant's agents, saved prompts and instructions): `context.addSettingsSection`, removed on unload; `context.openSettings(pluginID:)` opens that page |
| `EditorSelectionChanged` | PluginKitUI | sent by the editor plugin when the text selected in an open note changes (`text` empty once cleared): the Assistant takes the passage as context |
| `Panel`, `Slot`, `PanelOption` | PluginKitUI | puts a view in a slot (`.leading`, `.statusBar`; a `.trailing` panel shows as a group of "Info"), ordered by `order`; its `options` are display switches the shell shows under it in Settings > Sidebars (Files: "Show recent notes") |
| `SidebarLink` | PluginKitUI | adds a row (title, symbol, resource) to the navigation group at the top of the left sidebar with `context.addSidebarLink`; a click opens the resource (Tasks, Calendar) |
| `ViewRegistry`, `PanelRegistry` (`ui.views`, `ui.panels`) | PluginKitUI | where views and panels go; `ViewRegistryStore` and `PanelRegistryStore` are the standard ones |
| `QuickPick` (`ui.quick-pick`) | PluginKitUI | shows a filterable list in the shell's popup (`show(placeholder:items:choose:)`) and gets the choice; the palette and Cmd+O use it; `Fuzzy` ranks the rows |
| `Toasts` (`ui.toasts`) | PluginKitUI | shows a short message along the bottom of the window (`show(_:isError:)`), the same toast a command's answer uses; for work that ends on its own, such as a video compressed in the background |
| `CommandLauncher` (`ui.commands`) | PluginKitUI | runs another plugin's command by id from a button (`run`), asks whether it is there (`isAvailable`) and its current shortcut (`shortcut(for:)`, `⌘N`); the home page's actions |
| `Resource.home` (`home:`) | PluginKitUI | the home page: a plugin registering a view for it (`HomeUI`) becomes what the house button, a new tab and an empty window show; without one the shell falls back on the first sidebar link |
| `DragPayload`, `.draggableResource(_:)` | PluginKitUI | makes a row draggable into the workspace (a resource, or a tab inside the shell) under a private type |
| `ThemeTokens`, `Theme` | PluginKitUI | reads colours (`accent`, `text`, `secondaryText`, `background`, `separator`, `codeBackground`, `link`, `marker`), fonts, line height, column width and spacing from `@Environment(\.themeTokens)`; never hard-codes them. The shell's `ThemeStore` builds them from `.loam/themes/<name>.json` (`Theme`, see [THEMES.md](THEMES.md)) for the window's appearance; `.standard` is the system look |
| `EditorService` (`editor`), `SlashItem`, `TextChange` | PluginKitUI, provided by the editor plugin | adds slash items, inserts text at the caret of the open note; optional, with defaults (nil, false, no-op) so other editors still conform: `text(of:)` (live text of an open note, unsaved typing included), `reveal(line:in:)` (caret and scroll to a 1-based line of the active note), `addCodeBlockRenderer`, `addCodeBlockView`, `addFileDropHandler`, `addEmbedRenderer`, and `beginDraft(at:text:)` / `isDraft(_:)` (a new note with no file: the editor writes it once it holds text, and removes one it wrote that is left empty, when its tab closes or the app quits; a note that was on disk before the session is never removed) |
| `CodeBlockRenderer`, `CodeBlockRequest`, `RenderedCodeBlock` | PluginKitUI, drawn by the editor plugin | draws closed fenced code blocks of some languages as pictures (` ```mermaid ` by `DiagramsUI`): the editor asks with the code and the page's colours and font, keeps the pictures, shows one in place of its block, and the code with the picture under it while the caret is in the block. Code that cannot be drawn stays code; the note never changes |
| `FileDropHandler`, `DroppedFiles` | PluginKitUI, called by the editor plugin | takes the files dropped on a note (from Finder) or pasted into it (a copied screenshot, as PNG bytes): the handlers are asked in turn until one returns Markdown, which the editor inserts where they were dropped (at the caret for a paste) on lines of their own, undoable. With no handler the editor takes no files |
| `EmbedRenderer`, `EmbedRequest`, `RenderedEmbed` | PluginKitUI, shown by the editor plugin | shows image links alone on their line (`![](assets/clip.mp4)`) to vault files of some extensions: the editor resolves the link (from the note, else from the vault's root), asks again only when the file changes, and draws the picture (`image`) or hosts the view (`view`: a player, kept while its line stays) in place of the line, and the line with the embed under it while the caret is on it. A link that cannot be shown stays text; the note never changes |
| `CanvasCamera`, `infiniteCanvasNavigation`, `CanvasDotGrid(Layer)`, `CanvasZoomControls(View)` | PluginKitUI | the building blocks of an infinite canvas (used by the board, `CanvasUI`): a camera (offset, scale, zoom around a point, fit, reveal, animated moves on the display's frames), scrolling and pinching for SwiftUI (`infiniteCanvasNavigation`) and AppKit (`scroll(with:at:)`, `magnify(with:at:)`), the dot grid and the zoom capsule, in AppKit with SwiftUI wrappers |
| `CollectionViewType`, `CollectionViewRegistry` (`collections.views`), `CollectionViewModel` | PluginKitUI, registry provided by `CollectionsUI` | adds a kind of collection view (the `type:` of a view in a `.base`: `table`, `kanban`, `cards`, a third party's `calendar`) with `context.addCollectionView`; the view gets a model with the result, the search text and the actions (set a value, new entry, edit the definition) |
| `ResourceAction` (`ui.resource-actions`) | PluginKitUI | adds an item to the menu of a file or folder row ("Turn into Collection") with `context.addResourceAction` |
| `CodeBlockView`, `CodeBlockContext` | PluginKitUI, hosted by the editor plugin | shows closed fenced code blocks of some languages as a live SwiftUI view (` ```base ` as a collection): one view per block, built once and kept while the block stays, in the room under the block (its own height, scrolling inside past 560 pt), the code shown above it while the caret is in the block. The view reads `code` and `isEditingCode` live and edits only through `replaceCode` (one undo step, saved as typing) and `editCode` (caret into the code); Escape gives the keyboard back to the text. Wins over a renderer of the same language |
| `DocumentTextChanged` | PluginKitUI, sent by the editor plugin | the text of an open note changed (about 300 ms after typing stops); read it with `editor.text(of:)`. Saving still sends `VaultChanged` |

The `PluginContext` helpers of `PluginKitUI` are the way in: `registerView`, `registerPanel`, `addSidebarLink` (they throw
`UIContractError.registryMissing` without the shell), `workspace`, `quickPick`, `editor`, `addSlashItem`, `addCodeBlockRenderer`,
`addCodeBlockView`, `addFileDropHandler` and `addEmbedRenderer` (no-ops without an editor), `addResourceAction` and
`addCollectionView` (no-ops without their registry). Each registration is undone when the plugin unloads.

**Writes and open editors.** The editor keeps unsaved typing for up to 500 ms, while any plugin may read and write
the same note through `context.vault` (a task toggled, a property set, a line appended to the daily note). The
kernel gives each plugin a `context.vault` that announces its reads and writes (`NotifyingVault`), and the editor
plugin listens, ignoring events carrying its own id: on `NoteWillRead` from another plugin it saves the note at once
if it has unsaved typing, so a plugin that reads, edits and writes starts from the text the user sees; on
`NoteDidChange` it reloads the note at once (not when the file system reports it), so the editor shows the plugin's
change and its next save cannot overwrite it. A note with unsaved typing at that point (typed between the plugin's
read and its write, which only a plugin running off the main thread allows) keeps the user's text, as for any outside
change: merging is not done. The editor does not act on `NoteWillChange`: saving then would only write text the
plugin is about to replace. A plugin never needs to know an editor exists; it reads right before it writes.

**Attachments.** A file dropped or pasted into a note goes through the `attachments` service: the Attachments plugin
copies it into one folder at the vault's root (`assets` by default, unsorted, `name 2.png` when taken) and the note
gets a plain link written from the vault root, which survives the note moving (links relative to the note are read
too, and the note graph keeps both forms right when a note or the file moves): `![](assets/photo.png)` for media
(images, sound, video, PDF) and `[report.zip](assets/report.zip)` for any other file. SVG, Ogg and Opus files get a
plain link, since nothing shows them. Obsidian's `![[file]]` embeds are not rendered; the Obsidian importer converts
them to `![](…)` links. `AttachmentsUI` is the editor side (the drop handler and the
embed renderers). A plugin that changes files, such as a compressor, hooks in at one of two points:

- **On the way in**: `context.addAttachmentProcessor(AttachmentProcessor(id:kinds:process:))` (with `attachments` in
  `optionalRequires`). Every import runs the processors whose `kinds` match, in the order they were added, each on
  the previous one's `AttachmentImport`; a processor returns new `contents` (`.data` or a `.file` it wrote in a
  temporary folder) and may change the `name`'s extension (`IMG.heic` to `IMG.jpg`). The link is written for the name
  that comes out. A processor that throws is skipped, so the user's file always goes in. Processors are async and
  hold the import, and the note's link, until they return: keep them to what takes a moment.
- **Later**: listen to `AttachmentImported`, do the slow work (a video), then `replace(path, with:, name:)`: the old
  file goes to `.trash/`, a new name moves the file and the note graph rewrites every link to it, and
  `AttachmentReplaced` follows. Open editors reload the rewritten notes and show the new file.

**Media compression.** The `Squeeze` plugin ("Media compression", needs `attachments` and `note-graph`) makes every
file that arrives in the vault smaller by default, using the `attachments` contract
and nothing else new. It declares the `shell` permission, because it runs `ffmpeg` and `cwebp`.

- **On the way in** (an `AttachmentProcessor`, so the link has the final name): PNG, JPEG, TIFF and HEIC become WebP
  (`cwebp -q 80`, or `ffmpeg` with libwebp; a JPEG with an EXIF rotation goes through `ffmpeg`, which applies it;
  HEIC is first converted by `sips`), sounds become mono 64 kbps (MP3 stays MP3, the rest becomes AAC in M4A).
  The colour profile (Display P3 screenshots and photos) is kept (`cwebp -metadata icc`); the `ffmpeg` fallback drops
  profiles, so a picture that has one is left alone there. Animated GIFs and PNGs (APNG), WebP and SVG are never touched. A pasted picture, which exists nowhere else, keeps its original in
  `.trash/`; a dropped file is still where the user dropped it.
- **Right after** (an `AttachmentImported` listener, then `AttachmentsService.replace`): videos (MP4, MOV, M4V) become
  H.264 MP4 at CRF 28, 1080p at most, and PDFs become pages of JPEG (130 dpi, quality 70) through the `pdf-rasterizer`
  service. They take longer, so the file goes in as it is and shrinks in the background, one at a time; `replace`
  puts the original in `.trash/` and the note graph rewrites the links when the extension changes (`.mov` to `.mp4`).
- **The rules**: a file is replaced only when it gains more than 10% (PDFs: more than 30%, since they lose their
  selectable text, links and search; the setting's name says so), and a sound or video only when its duration stays
  within 2%. MP3/M4A at or under the target bit rate, MP4 under 1.2 Mbps and files under the minimum size (100 KB) are
  left alone. Loam remembers what it optimized (size and checksum, in `.loam/squeeze-optimized.json`), so "optimize all"
  never encodes the same lossy file twice; asking for one file by name always tries. The "optimizing in the background"
  toast shows only once the file passed those checks. A missing tool means one toast naming it and the file kept as it is.
- **Settings** (`plugins.squeeze.settings`): the tool paths (found in `~/.homebrew/bin`, `/opt/homebrew/bin`,
  `/usr/local/bin` at first run), a switch per kind, WebP quality, audio bit rate and mono, CRF, maximum height, PDF
  dpi and quality, minimum size, keeping originals in `.trash/` and the excluded folders. Their titles and
  help come from the manifest's `settings:`.
- **Commands**: `squeeze.optimize` (`path`) and `squeeze.optimize-vault` (`confirm=true`, else only a count) for the
  command line and agents; `squeeze.pick` ("Optimize a media file…", a popup of the vault's media, biggest first) and
  `squeeze.optimize-all` ("Optimize all media in the vault…", asks, then reports what it saved) in the palette, from
  `SqueezeUI`, which also draws PDFs with PDFKit and shows the toasts.

**Files other than notes.** Notes are `.md`, but a plugin may own another file type (a `.canvas` board) by
registering a `ViewType` whose `canOpen` accepts its extension. The core then treats those files as it treats notes,
without knowing the type: `VaultChanged` reports them (listeners about notes skip them with `noteChanges`; the note
graph, tasks, search and the note panels do), the tab of a deleted file closes, a tab's title drops the extension
(`Resource.name`), a Markdown link to the file (`[Board](Boards/Board.canvas)`) opens it in Loam instead of in its
own app, and the Files panel shows it with the view type's `symbol`, without its extension, and keeps the extension
on rename. A file no view type opens is an attachment: links open it in its own app, and it keeps its whole name.

`FileViewersUI` is the plugin that gives the common file types a viewer, so no file is left to "No installed plugin
can open this": pictures (`files.image`: ImageIO formats incl. HEIC, WebP and SVG, fit and zoom), PDFs (`files.pdf`:
PDFKit, with search), videos and sounds (`files.media`: AVKit) and, below every other type, a Quick Look preview
(`files.preview`) for the rest. Each shows a footer with the file's name, kind and size and buttons to open it with
its default app or reveal it in Finder. These viewers set `keepsExtension` on their `ViewType`, so tabs
(`ViewRegistry.title(for:)`) and the Files panel show `photo.heic`, not `photo`; a plugin's own format (a board)
does not set it. A plugin that owns a type registers its view with a higher priority and wins.

Deleting a note is a move into `.trash/` (it works on Linux, and is recoverable); never the macOS Trash, never a plain
removal. The `trash` plugin (`TrashService`, `trash.*` commands) keeps when each item was trashed in
`.trash/.trashed.json` (the date and the original path, without touching the file's dates; restoring goes back to that
path), and deletes items for good after 30 days (the `retentionDays` setting, 0 to keep them); `TrashUI` shows them as
Recently Deleted and runs the purge when a vault opens and every hour. An item put in `.trash/` by another tool counts
from the day Loam first sees it. Enabling, disabling and listing plugins are commands (`plugins.list`,
`plugins.enable`, `plugins.disable`), and so are reading and changing their settings (`plugins.settings`,
`plugins.set-setting`, on `Runtime.settingFields` and `setSetting`), so the settings window, the CLI and agents share
one path.

**Third-party plugins.** A vault's own plugins (`.loam/plugins/<id>/plugin.json`, compiled in `.loam/cache/plugins/`)
are listed by `plugins.list` with `source: "vault"` and are **off by default**: one runs only when `.loam/config.json`
says `"enabled": true`, and its library is opened only then. Disabling deactivates it; its code stays loaded until
the app quits. `PluginLoader` reports every problem as a load error instead of failing ([PLUGIN-LOADING.md](PLUGIN-LOADING.md)).

**Safe mode.** Holding Option at launch, `--safe-mode`, or two launches in a row that did not stay up 5 seconds
(`LaunchGuard`) open the vault with only an allowlist of plugins, `ShellConfiguration.safeModePlugins`; the
`Runtime` adds the providers they require. Safe mode never opens a third-party library. The app keeps `markdown-editor`, `file-explorer` and `files`, so notes
can still be found and edited. A banner offers to restart normally.

**Resident mode.** Loam keeps running when its window is closed (`ResidentMode`, Settings > Appearance > In the Background, on by default), so quick capture's shortcut and the menu-bar icon keep working; ⌘Q quits. Reopening the app (Dock, `NSWorkspace.openApplication`) brings the window back. "Open Loam at login" is a login item (`SMAppService`), off by default.

**Shortcuts.** A command may declare a default shortcut; `.loam/config.json` overrides it (`""` removes it). Cmd+P
opens the palette and Cmd+O the quick switcher, so Open Vault is Shift-Cmd-O. Standard editing and system shortcuts
are reserved (Cmd+Z, Shift-Cmd-Z, Cmd+X/C/V/A, Cmd+F, Cmd+Q, Cmd+H, Cmd+M, Cmd+,); conflicts are shown in settings.
The shell's `ShortcutTable` resolves them (the first command id in sort order wins a conflict) and its `KeyMonitor`
runs them from the vault window, leaving a key to the menu bar when an enabled menu item has the same equivalent, and
to the focused view when the command's `isShortcutEnabled` says no: a view's own keys (the mindmap's ⌘ arrows) live
as commands without taking ⌘← from the caret in a note. A key without ⌘ or ⌃ (the mindmap's Tab) is a command's
`viewKey`, not a shortcut: the palette shows it, the shell never takes it, and the view that has the keyboard
handles it.

Placement is a hint, not an order: a shell without splits treats `.beside` as `.newTab`. A plugin that needs to
know more than the hint is asking for a missing contract; add it here instead.

When several view types can open one resource (a `.md` note as text or as a board), the highest priority wins. A
tab can remember another choice (`Tab.viewType` in `WorkspaceModel`), set by the page's view switcher or "Open with".
The choice is saved with the window layout, per machine in `.loam/cache/`. Per-file persistence is not built: no code
writes it to `.loam/config.json`.

## Dependency rules

1. **Contracts, not plugins.** A capability shared between plugins is a protocol with a `ServiceKey`. Domain
   services (note graph, daily notes, note queries) live in `PluginKit`; UI services (workspace, editor) in
   `PluginKitUI`. The provider lists the id in `provides`, the users in `requires` or `optionalRequires`.
2. **Prefer optional.** A plugin degrades when an optional service is missing. A Kanban plugin without the editor
   still shows boards; it just offers no `/board` item.
3. **Disabling cascades, visibly.** Disabling a provider also deactivates the plugins that require it. The plugin
   manager lists them before confirming. Optional users stay active and see the service disappear.
4. **Breaking a contract gets a new id.** `note-graph` becomes `note-graph.v2`; the old one stays until no
   plugin needs it. Adding a method with a default implementation is not breaking.
5. **No global state.** Everything goes through the context, so unloading leaves nothing behind (tested).
6. **Small contracts.** A protocol with more than a handful of requirements is two contracts.

## The vault carries everything

A vault is portable: copy the folder to another Mac and the whole app comes with it.

```
My Vault/
├── notes and folders, any depth      plain Markdown
├── assets/                           files dropped or pasted into notes, unsorted (the Attachments plugin)
├── <Folder>/<Folder>.base            a collection: views over the folder's notes (Obsidian Bases YAML)
├── .loam/
│   ├── config.json                   enabled plugins, their settings, shortcuts, theme
│   ├── plugins/<id>/                 third-party plugins: plugin.json, and their Swift package sources
│   ├── themes/<name>.json            theme tokens (colours, fonts, editor), see THEMES.md
│   └── cache/                        disposable: note index, compiled plugins (plugins/<id>/), window layout
├── .trash/                           deleted notes, recoverable for 30 days (.trashed.json holds the dates)
└── .git                              with Git sync: a folder, or a file pointing to git's data elsewhere
```

- Changes inside `.git` trigger no refresh: the file watcher skips them (git writes there many times per command).
- Deleting `.loam/cache/` loses nothing. Deleting `.loam/` loses settings and plugins, never a note.
- Compiled plugins depend on the machine (CPU, Swift version), so they live in the cache and are rebuilt from the
  sources in `.loam/plugins/`.
- First-party plugins ship inside the app; `config.json` only records whether they are on.
- The window layout (open tabs and splits) is per machine, in the cache, so two Macs syncing one vault do not
  fight over it.

## The workspace

A tree: the workspace holds splits; a split holds panes or other splits; a pane holds tabs; a tab shows one
resource with one view type. Dropping a tab or a note on the edge of a pane splits it. A view can save a small
`Codable` state per tab (caret, scroll, zoom) that the shell keeps with the layout.

The layout itself is `WorkspaceModel` (App/): value types (`WorkspaceLayout`, `Tab`, `Pane`) with no view code, holding the placement, close, drop and
collapse rules, unit and fuzz tested. The shell only renders it and forwards user actions to it.

A plugin makes something draggable into the workspace with `.draggableResource(_:)` (`PluginKitUI`). Drags carry a
`DragPayload` (a resource or a tab id) under a private type, not plain text, so the editor's text view never takes a
workspace drop. The pane and tab bar drop targets only measure the pointer (`dropEdge`, `tabInsertionIndex`) and
call `WorkspaceController.perform`.

## Repository layout

`Sources/PluginKit` (SDK), `Sources/LoamCore` (kernel), `Sources/Plugins/<Name>` (first-party plugins),
`Sources/BuiltinPlugins` (their list), `Sources/LoamCLI` (command line logic). Tests mirror it under
`Tests/`. `Package.swift` builds the plugin targets from one `plugins` list, and its only product is the dynamic
`LoamRuntime` holding all of them. `CLI/` is the `loam` executable's own package (on the runtime library).

`App/` is a separate package (macOS 26, Swift 6.2) that uses the root package by path: `PluginKitUI` (the UI
contracts), `PluginKitUITesting` (`UIPluginHarness` and fakes), `Sources/Plugins/<Name>UI` (the UI plugins: one
module each, on its logic module when it has one), `BuiltinUIPlugins` (their list), `MarkdownEditor` (the TextKit 2
editor the `MarkdownEditorUI` plugin wraps), `WorkspaceModel` (the layout as value types), `NotebookApp` (the shell:
window, workspace, slots, palette, settings, safe mode; it imports no plugin), all in the dynamic
`LoamUIRuntime`. `App/Executable/` is the app executable's own package (`Loam`, which passes the
plugin lists to the shell). Tests mirror it under `App/Tests/`, UI plugins under `App/Tests/Plugins/<Name>UITests`.

Executables never link PluginKit or PluginKitUI statically: third-party plugins share the runtime libraries with
them, and a second copy of a type breaks them ([PLUGIN-LOADING.md](PLUGIN-LOADING.md)). Depend on the
runtime products only, never add another product to the root package or `App/`.

`Examples/HelloPlugin` is a third-party plugin built outside the app (`loam plugin install Examples/HelloPlugin`). `scripts/`: `swift.sh` (Swift natively or in a
container), `build-app.sh` (the bundle), `build-cli.sh` (`make release`), `build-example-plugin.sh <vault>`,
`stamp-build-id.sh` (the runtime build id), `check-single-copy.sh` (no type in two images), `check-plugin-api.sh`
(the plugin SDK only grows), `make-test-vault.sh`.

### The window's shell

The window is AppKit from its root (`ShellRootView`, under a `ShellWindow` that only hands it the theme): the canvas,
the side columns, the title bar row's buttons, the overlays, the palette and the toasts are laid out by hand, and each
part follows what it shows (`Follow`), so a window resize, a divider drag, a pane opening beside, a note switch or a
sidebar's slide lays out and draws as little as it can, and never evaluates a whole-window SwiftUI body. What plugins
give the window (the sidebars' panels, the inspector, the overlays) stays SwiftUI, each in a hosting view of its own:

- `SplitTreeView` (`NotebookApp/Views`) lays the `WorkspaceLayout` tree out by its fractions in `layout()`, with
  AppKit dividers (`SplitDividerView`), and plays the sidebars' slides on the workspace's layer (`follow`).
- `PaneHostView`, one per pane: its tab bar (`TabBarView`, the tabs a SwiftUI `TabStrip` as wide as they are, in a
  scroll view), its page (`PageChromeView`: background, ring, shadows and rounded clip as Core Animation layers) and
  the page's drop target (the zones are SwiftUI, hosted over the page only during a drag).
- `PageStackView`, the page's content: each page of the selected tab (and the pages it keeps, `keptPages`, and the
  last page of the last two tabs) in a hosting view of its own (`PageView`), the toolbar's in another over them.
  A page arriving or leaving moves as a Core Animation layer (`PageChange`'s pose, `sublayerTransform` and opacity),
  so the motion never waits for the main thread. A view type with an AppKit view (`ViewType.makeNSView`, All Notes'
  `CardGridView`) is put in the page as it is, with no hosting view, and told the theme and the toolbar's room
  (`NativeHostedView`). A plugin's SwiftUI view stays as it is, as the side columns are in
  `SlidingColumnView`. A hosting view starts from SwiftUI's defaults, so the window's values
  for its pages are handed over explicitly (`PaneEnvironment`: theme, canvas, page actions, sidebar edges, the
  tab bar's room); a plugin's page reads them as before (`PaneHostTests`). Plugins and the SDK see no difference.

Every movement there takes its numbers from `Motion` and follows [design/MOTION.md](design/MOTION.md).

CI builds `App/` on the `macos-26` runner (Swift not pinned), and a dev Mac may have another Swift: pass function values to SwiftUI (a `Binding`
setter, an action) wrapped in a closure literal, `{ model.close() }`, never as a bare reference.

On a machine without Swift, `make test` runs in a `swift:6.0` container (podman or docker, see `scripts/swift.sh`).
Remove the image afterwards with `podman rmi docker.io/library/swift:6.0` (or `docker rmi`) if disk space matters.

## Testing

- `PluginKitTesting` (root package) provides `TemporaryVault` and `PluginTestHarness` (a kernel and plugin host on
  a temporary vault), so a logic plugin is tested without the app.
- `PluginKitUITesting` (App/) provides `UIPluginHarness`: the same, with the host services in place (the real
  `ViewRegistryStore` and `PanelRegistryStore`, `RecordingWorkspace`, `RecordingQuickPick`, and optionally a
  `RecordingEditor`), plus `render(_:)`, which lays a view out in an offscreen window.
- `BuiltinPluginsTests` checks every logic plugin; `BuiltinUIPluginsTests` does the same for UI plugins, with the
  logic plugins available: each activates alone and with the others, unloading leaves no command, view or panel
  behind, every view and panel renders offscreen, and commands have a dotted id and a useful summary. A probe UI
  plugin in the test file keeps the checks meaningful while the list is short.
- The shell has its own tests (`NotebookAppTests`), with a test plugin standing in for real ones, and
  `EssentialPluginsTests`, which hosts the real lists and turns each essential plugin off.

## Platforms

A screen that moves or shows many views at once is AppKit, in one implementation: no SwiftUI twin is kept for
another platform, for an embedded case or for tests ([APPKIT.md](APPKIT.md)). The rest of `PluginKitUI`'s
contracts (panels, settings, code blocks, a plugin's own `makeView`) are SwiftUI; an iPhone shell would draw its own
version of the AppKit screens when it is built. Placement stays a hint, so a shell can lay pages out its own way.
