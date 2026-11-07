# Design

The app is called Loam. The product vision is in [VISION.md](VISION.md); this file holds the technical choices.

## Vision

A simple, fast Markdown note-taking app for macOS and iOS, in the spirit of Bear. The base does one thing well:
write Markdown notes. Everything else is a plugin, so the app can become whatever its user needs: a mindmap tool,
a Granola-style meeting recorder, bases, a habit tracker, dashboards, a project board.

The product is the community and the platform, not a fixed feature list:

- **Open source community.** Anyone can write a plugin and share it.
- **AI native.** In 2026 agents write the plugins. The app is designed so an agent can extend it in minutes: a small
  SDK with high-level building blocks, plain Markdown data, documented extension points, and a skill that teaches
  an agent how to add a brick.
- **Simple and flexible at once.** The base stays minimal and fast. Flexibility comes from plugins, never from
  complexity in the core.

## Principles

- **Simple base, unlimited reach.** If a feature is not needed by every user, it is a plugin.
- **Local first, Markdown first, nothing proprietary.** Notes are plain Markdown files in a folder. No custom
  syntax, no custom file format. Anything an agent already knows (CommonMark, GFM, YAML frontmatter, JSON Canvas)
  beats something we invent.
- **Everything is a plugin.** The core is minimal; the editor, daily notes, backlinks, search, importers, canvas,
  mindmap, meeting notes and the AI assistant are all plugins.
- **AI native.** An agent can add a brick to the app. The SDK provides the high-level pieces so a plugin stays small.
- **Native.** Swift and SwiftUI, no webview. One exception: a plugin may embed an established open-source editor in
  a web view, offline and from the app's own resources, when rewriting it would take months and its files stay an open
  format in the vault. Excalidraw is the one so far ([EXCALIDRAW.md](EXCALIDRAW.md)).
- **Check against VISION.md.** Every decision here serves the vision; if one does not, change the decision.

## Vault format

- A vault is a folder of `.md` files (CommonMark + GFM), organised by plain folders. No sub-pages, no folder notes.
- Properties are YAML frontmatter.
- Collections (a table, a board, a gallery of notes) are `.base` files: Obsidian Bases YAML (`filters`, `properties`,
  `views`), the format agents already know for views over notes. The entries stay notes, their fields frontmatter.
  Loam reads and writes the keys it knows and keeps the others, and adds three of its own: `type` and `options` under
  `properties.<name>` (a field's kind and a select's ordered options) and the `kanban` view type. A folder's own
  `<Folder>/<Folder>.base` makes the folder open as that collection, and the explorer hides the file: the one
  exception to "no folder notes", since a `.base` is not a note. The same YAML in a ` ```base ` block shows the
  collection inside a note; the "Collection", "Kanban" and "Gallery" items of the `/` menu insert one over the notes
  whose `collection` property is the note's name (`collection == this.file.basename`). Its "+" writes the new note
  next to the note with that property, so no folder appears, and renaming the note renames the property.
- Links between notes are standard relative Markdown links, `[Title](folder/Note.md)`. They render in any viewer.
  The app rewrites them when a note is renamed. Typing `[[` offers completion and inserts the standard link.
- `.loam/` at the vault root holds what makes the vault portable: `config.json` (plugins, settings, shortcuts,
  theme), third-party plugin sources, themes, and `cache/` (index, compiled plugins, window layout). Deleting
  `cache/` loses nothing; deleting `.loam/` never loses a note. Details in [ARCHITECTURE.md](ARCHITECTURE.md).
- Files dropped or pasted into a note (images, sound, video, PDFs, anything) are copied into one folder at the vault's
  root, `assets/` by default, unsorted, and linked with a plain link from the vault root: `![](assets/photo.png)` for media,
  `[report.zip](assets/report.zip)` otherwise. The folder's name, and hiding it from the file explorer, are the
  Attachments plugin's settings.
- Deleted notes go to `.trash/` in the vault, recoverable for 30 days (then deleted for good), listed in Recently Deleted.
- Daily notes: `Journal/YYYY/MM Month/YYYY-MM-DD.md` (folder and sorting configurable), with a configurable template.
- Canvas: JSON Canvas (an open spec), `.canvas` files whose cards point at notes, so a note sits on many boards
  ([CANVAS.md](CANVAS.md)). A mindmap is a note; on a board it is a card showing that note as a map.
- Drawings: Excalidraw scenes, saved as the Obsidian Excalidraw plugin saves them, a note named
  `Name.excalidraw.md` flagged `excalidraw-plugin: parsed`: its text in `## Text Elements` (search and links see it),
  its images as files in `assets/`, the scene as JSON. Plain `.excalidraw` files open too ([EXCALIDRAW.md](EXCALIDRAW.md)).
- Obsidian compatibility is by file format, not by app: `.base` files are read as Obsidian writes them, and drawings and boards use the formats Obsidian reads (see above). An import plugin converts an Obsidian vault (wikilinks to standard links, callouts,
  canvas, daily notes).

## Look

Native macOS 26, light by default, modelled on Craft ([design/CRAFT.md](design/CRAFT.md)): one flat light grey
window behind the sidebars and the tabs, each pane an opaque white rounded page detached from the window's edges (a
hairline ring and a soft shadow). Each pane's tabs sit in the title bar row (Home first), the selected one a white raised capsule, as is the
current sidebar panel; each page has its own toolbar (Back, New Note, the right sidebar). The right sidebar is
Craft's inspector and follows the focused tab: a few short tabs (a note's Outline, Links, Stats, Insert; a mindmap's
Style), as titled groups of white cards, tiles and figures, with nothing the page already shows. The
left sidebar reads like Craft's: the vault's name with a badge, "New Note", the navigation links (Tasks,
Calendar), then the Files panel's "Folders" ("Recent" above it is a display option in Settings > Sidebars, off by
default); rows
are 14 pt, 34 high, the selection a neutral grey. The floating controls are Liquid Glass: the command palette and
quick pick as a frosted sheet over a dimmed window with the selected row filled with the accent, and toasts. The
accent is the design's blue unless a theme or Settings > Appearance sets another; a theme with its own background
gets a shade of it as the window. The shell draws it all (`NotebookApp/Views/Glass.swift`, `PageChromeView`, `ShellWindow`); plugins
only read `ThemeTokens`.

Narrow panes degrade softly, as Craft's do: a page never grows past its pane (what doesn't fit is cut by the page),
lists fade out at the edges that have more to scroll (`softScrollEdges`), and a line too long for its card or column
fades out at the edge (`fadingEdges`, `fadingOverflow`, in `PluginKitUI`) rather than wrapping letter by letter.

Settings (Cmd+,) is laid out as Craft's: a sidebar on the window's grey (the vault's badge and name; Appearance,
Sidebars, Shortcuts; All Plugins and a row for each plugin with settings; About at the bottom) and the pane as a white
page, a centred column of titled groups, each a light grey rounded card of rows (switches, pickers, fields, blue
actions). A plugin's row opens its own page, with its settings drawn from its `PluginSettings` (`NotebookApp/Settings`).

The window starts simple: each side column shows only its first panel (Files on the left, backlinks on the right).
Settings > Sidebars turns the others on; the choices go to `.loam/config.json` as `"panels": { "<id>": true | false }`
(`PanelVisibility`).

## Editor

Plain Markdown on disk, a page like Craft's or Notion's on screen: blocks (paragraphs, headings, list items, tasks,
quotes, code, tables...) whose text holds no syntax at all, so a caret, a selection or a delete key never meets a
`**` or a `---`. The note is read into blocks when it opens and written back as Markdown, byte for byte where
nothing was edited. See [design/BLOCK-EDITOR.md](design/BLOCK-EDITOR.md). A bullet is a dot, a task a round
checkbox, a quote a bar, a divider a hairline, and a `#` title gets a hairline under it. Markdown typed at the start
of a block (`# `, `- `, `[] `, `> `, `---`, ```` ``` ````) or around words (`**bold**`) becomes the block or the style,
as in Notion. The `/` menu only inserts standard Markdown (headings, lists, task lists, quote, code block, table,
divider, link, image, GitHub-style alert), so beginners never type the syntax. Rich blocks come from plugins: a
plugin draws a fenced code block of its language as a picture (` ```mermaid ` as a diagram) or a live view
(` ```base ` as a collection), and an image link alone on its line shows what it points to (a picture, an animated
GIF, a video or sound in the system's player, Craft's PDF card). Those are components, one block each: their code or
link is edited on their code page or with their own controls, never shown in the text. View Markdown Source (⇧⌘U)
shows the whole file as it is written.

## Core (minimal)

The kernel: vault and file watching, event bus, command registry, service registry, plugin host, settings. The
shell on top: window, workspace (tabs, splits, drag and drop), sidebar and status bar slots, command palette
(Cmd+P), settings window and plugin manager, safe mode. Everything else is a plugin, including the editor, the file
explorer and Cmd+O. What goes where, the contracts plugins use and the dependency rules are in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Plugins

- Native Swift, built against `PluginKit`. First-party plugins are modules compiled with the app.
- **Services, not plugin ids.** A manifest `provides` and `requires` service ids. The host activates providers first,
  reports a missing service or a cycle, and refuses two providers of one service. Any plugin, the editor included,
  can be replaced by another that provides the same service.
- **One context per plugin.** Commands, services and listeners registered through it are undone when the plugin
  unloads, last registered first. A plugin never cleans up by hand. A failed activation rolls back everything.
- **Typed events** with two dispatch modes: `emit` (observe) and `waterfall` (wrap, transform or short-circuit).
- Loading: a plugin is a SwiftPM package in `.loam/plugins/<id>/` of the vault. `loam plugin build` compiles it to a bundle the app
  loads at the next launch, in the same process so SwiftUI views integrate. No hot reload (Swift cannot unload code
  reliably). Loading self-built bundles needs macOS library validation disabled.
- Install: `loam plugin install <git url>`, or `loam plugin install --catalog <id>` for a plugin of the community catalog (`loam plugin catalog <query>` searches it). Not built: automatic static analysis of plugin code.
- **Safe mode** like Obsidian's: only `markdown-editor`, `file-explorer` and `files` load, and vault plugins never do (`App/Executable/Sources/Loam/main.swift`). It starts when Option is held at launch, with `--safe-mode`, or
  after two launches in a row on a vault that did not stay up for 5 seconds (`App/Sources/NotebookApp/SafeMode/LaunchGuard.swift`). `resolveOrder(enabled:)` only orders plugins by their dependencies (`Sources/LoamCore/PluginHost.swift`).
- Manifests declare permissions (`vault.read`, `vault.write`, `network`, `audio`, `shell`), as in `Sources/Plugins/Squeeze/SqueezePlugin.swift`.

## SDK

`PluginKit` is the protocols (no UI, builds on Linux). `PluginKitUI` is SwiftUI building blocks (table, board, list,
form) and the property-query API on the note graph, so a plugin such as a Kanban is a few dozen lines. The app's own
features are written the same way.

## One command registry

A plugin registers a command once. It appears in the command palette, the CLI, the AI assistant's tools and a future
MCP server. The CLI works without the app running.

## Search and index

- [truffle](https://github.com/Azilone/truffle) provides search by name, content and meaning (embeddings), bundled
  as a local service and driven through its socket. The model downloads on first run.
- A small SQLite index holds the note graph only: links, backlinks, tags, properties. Rebuildable at any time.

## AI assistant

A chat panel like Craft's assistant. It drives the agent CLIs the user installed and signed in to (Claude Code, Codex, Antigravity CLI, Pi, OpenCode; `Sources/Plugins/Assistant/Agent.swift`). Loam starts each one in the vault and never sees its credentials. Edits are
shown as diffs to accept. Local models are supported, not a priority. Creating plugins is done with a skill
(`.agents/skills/plugin-dev`), not a dedicated in-app mode.

## Status

Built and tested (on Linux and macOS): the core and plugin host, the vault with change detection, and the plugins
NoteGraph, DailyNotes, HabitTracker, ObsidianImport, TruffleSearch and FileExplorer, all reachable from the `loam`
command line.

The Mac app (`App/`) is a shell that hosts plugins
and holds no feature code: tabs and splits, drag and drop of tabs and notes onto pane edges, the layout saved per
machine, the left and right sidebars, the command palette (Cmd+P) with shortcuts, the settings window with the
plugin manager, and safe mode. The essential features are plugins that can each be turned off: the Markdown editor
(live-styled TextKit 2, `/` menu, the `editor` service), the file explorer (folder tree, recent notes, create,
rename, move, trash) and the quick switcher (Cmd+O, open or create a note by name).

Also built: the Backlinks, Outline, Search and Calendar panels, Cmd+D for today's note, and
search that works without Truffle for names and content.

Also built: collections (`.base` files) with Table, Kanban and Gallery views, the `note-query` service, tasks across notes,
Kanban boards defined by a note's `kanban` property, the habits board, the graph of the vault and the mindmap of a note. Plugin writes go through a
notifying vault, so an open editor saves before another plugin reads a note and reloads after it writes: unsaved
typing and plugin changes no longer overwrite each other.

Plugins from anyone: the app links two shared runtime libraries, so a plugin built
separately shares every type with it; `loam plugin new|build|install|remove` (bundled in the app, building against the
SDK sources shipped in the bundle); vault plugins are off until the user enables them after seeing their declared
permissions; safe mode never loads them; themes from `.loam/themes/`. The app is named Loam.

Also built: the AI assistant, the "Open with" view choice, French UI and the community catalog (`loam plugin catalog`). Not built: an iPhone app (`App/Package.swift` is macOS only) and automatic checks of catalog plugins. Distribution needs a Developer ID, the hardened runtime and notarization.

## Later

Windows is reconsidered after v1.

## Constraints

- macOS 26 minimum. English code and docs; UI in English with French available.
- Distributed as a signed zip, outside the App Store (sandboxing conflicts with arbitrary vault locations and audio capture).
- No sync service of our own. iCloud Drive works as a plain folder; Git sync is an opt-in plugin (`git-sync`,
  [GIT-SYNC.md](GIT-SYNC.md)) over the user's own repository.
- Tests: a synthetic vault in the repo, plus a copy of the real vault on the user's Mac. Never the real vault.
