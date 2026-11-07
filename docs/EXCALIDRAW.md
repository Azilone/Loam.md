# Drawings (Excalidraw)

Loam's second board: Excalidraw, the hand-drawn whiteboard (shapes, arrows, a pen, text, images, libraries). The
card board (`.canvas`, [CANVAS.md](CANVAS.md)) arranges notes; a drawing is free-form.

## The file

A drawing is a note, written exactly as the Obsidian Excalidraw plugin writes it, so the same vault opens there too:

````markdown
---
excalidraw-plugin: parsed
tags: [excalidraw]
---

# Excalidraw Data

## Text Elements
Project kickoff, see [Roadmap](Roadmap.md) ^aB3dE5fG

## Element Links
Rk7mQ2pZ: [[Ideas]]

## Embedded Files
f0a1b2c3d4: [[assets/Plan f0a1b2c3.png]]

%%
## Drawing
```json
{ "type": "excalidraw", "version": 2, "elements": [...], "appState": {...}, "files": {} }
```
%%
````

- **Name.** `Name.excalidraw.md`; the note's title is `Name` (NoteGraph does not take `# Excalidraw Data` as a title).
- **The flag** `excalidraw-plugin` in the frontmatter makes the note a drawing; the `Drawing` view `prefers` it, as the
  mindmap view prefers notes flagged `mindmap-plugin`. "Open with" still shows its Markdown.
- **Text Elements, Element Links** are written from the scene on every save, one `text ^elementId` per text. Search,
  backlinks and agents read them. When they differ from the scene (an agent, a link rewrite edited them), they win on
  reading.
- **Embedded Files**: each image of the drawing is a file of the vault, `fileId: [[path]]`. A pasted or dropped image
  goes through the `attachments` service into `assets/`, named after the drawing. The scene's `files` stay empty in
  the note. Moving an image rewrites its line (`NotesMoved`). Bare names (`[[photo.png]]`, as Obsidian may write them)
  are found anywhere in the vault.
- **Drawing**: the scene as pretty, key-sorted JSON (readable, diffable). Loam also reads lz-string
  ` ```compressed-json ` (Obsidian's default) and keeps a compressed drawing compressed.
- Anything else (text above `# Excalidraw Data`, sections Loam does not know) is written back unchanged.

A plain `.excalidraw` file (excalidraw.com, ExcalidrawZ) opens in the same view and is saved as it came: the scene
alone, images inside.

The code: `Sources/Plugins/Excalidraw` (Foundation only: the format, `LZString`, the `excalidraw` service, the
`excalidraw.new`, `excalidraw.list`, `excalidraw.read` commands).

## The editor

`App/Sources/Plugins/ExcalidrawUI` shows the real Excalidraw (`@excalidraw/excalidraw`, MIT) in a `WKWebView`, the
one exception to "no webview" in [DESIGN.md](DESIGN.md).

- **Offline.** `scripts/vendor-excalidraw.sh` bundles Excalidraw, React and `scripts/excalidraw/bridge.js` with esbuild
  into `Resources/excalidraw/` (committed, about 9 MB, chunks loaded on demand), fonts included except Xiaolai (12 MB
  of Chinese glyphs, fetched from Excalidraw's CDN when a drawing uses it). A `WKURLSchemeHandler` serves the folder
  as `loam-excalidraw://app/`. Run the script only to change a version or the bridge.
- **The bridge** (`bridge.js`). The page posts `ready` once React mounted, `change` with the scene (`serializeAsJSON`,
  400 ms after the last edit, only when it changed) and `openLink`. Swift calls `loam.load`, `loam.setTheme`,
  `loam.flush` (the scene now: on tab close and when the app leaves the front), `loam.renderPNG`.
- **Saving.** `DrawingEditor` saves one change at a time through `ExcalidrawService.save`; a change on disk that is not
  its own write reloads the drawing.
- **Pictures.** A drawing on a board card or a folder page's card (`ViewContext.presentation == .embedded`) or linked
  alone on its line in a note (`![](Plan.excalidraw.md)`, an `EmbedRenderer`) shows as a PNG from Excalidraw's export, drawn in one offscreen
  web view and kept until the file changes. WebKit's canvas has no `filter`, so for dark pictures the bridge darkens
  the colours itself (`invert(93%) hue-rotate(180deg)`), images untouched.
- **Layout.** At Excalidraw's own narrow-width breakpoint, it uses its phone layout (tools at the bottom), as on the web.

## The library

Excalidraw's library (shapes and icons to drop on a drawing) is shared by every drawing of the vault: one
`.excalidrawlib` file (Excalidraw's own format), `.loam/excalidraw/library.excalidrawlib`, so it travels with the vault.
A change in one drawing is saved and shown in the other open ones.

"Browse libraries" opens libraries.excalidraw.com in a window of Loam (`LibraryBrowser`), not in the browser:
"Add to Excalidraw" there sends the page back to the editor's address with `#addLibrary=<url>`, which the system
cannot open (`loam-excalidraw://` is the web view's own). The window takes that address, downloads the library (only
from libraries.excalidraw.com, hence the `network` permission), and the drawing merges it and opens its library panel.

## Known gaps

- The tab title keeps `.excalidraw` (`Resource.name` drops only the last extension), as Obsidian shows it.
- An edit made less than 400 ms before quitting with Cmd+Q may be lost.
