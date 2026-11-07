# Boards

A board is a whiteboard of cards: notes of the vault, pieces of text, web pages and groups, joined by arrows. It
is a [JSON Canvas 1.0](https://jsoncanvas.org/spec/1.0/) file, `<name>.canvas`, the open format Obsidian also
writes. Nothing else: no database, no copy of the notes. A card showing a note only holds the note's path, so one
note can sit on many boards and is still edited as a note.

The `Canvas` plugin reads and writes boards (the `canvas` service and the `canvas.*` commands); `CanvasUI` shows
them in the app.

```json
{
	"nodes":[
		{"id":"a1","type":"file","file":"Projects/Trip.md","x":0,"y":0,"width":400,"height":400},
		{"id":"c3","type":"text","text":"**Dates**: May","x":480,"y":0,"width":260,"height":80,"color":"3"},
		{"id":"g1","type":"group","label":"Preparation","x":-40,"y":-40,"width":820,"height":480}
	],
	"edges":[
		{"id":"e1","fromNode":"a1","fromSide":"right","toNode":"c3","toSide":"left","label":"when"}
	]
}
```

## The file

- Nodes are listed bottom to top: the array order is the drawing order. A group goes under the cards it holds.
- `type` is `text` (Markdown in `text`), `file` (a vault path in `file`, a heading in `subpath`), `link` (`url`) or
  `group` (`label`, an optional `background` image).
- `x`, `y`, `width`, `height` are board units (pixels at 100 %), `y` grows downwards.
- `color` is a preset, `"1"` to `"6"` (red, orange, yellow, green, cyan, purple), or `"#RRGGBB"`.
- An edge joins `fromNode` to `toNode`. Sides (`top`, `right`, `bottom`, `left`) are optional: without them the
  facing sides are used. `toEnd` is `arrow` unless it says `none`; `fromEnd` is `none` unless it says `arrow`.
- A group holds the nodes lying entirely inside it: moving it moves them. There is no membership field.
- Loam adds three optional fields, which other apps keep when they write the file back: `fontSize` on a text node
  (board units, 16 when absent), and `shape` (`curve` or `straight`) and `dashed` on an edge.
- The whiteboard's pieces are written as the Obsidian plugin Advanced Canvas writes them ("Advanced JSON Canvas"), so
  it shows them, and plain Obsidian shows a card holding the same content:
  - a shape: a text node with `styleAttributes.shape` (`pill`, `diamond`, `parallelogram`, `circle`,
    `predefined-process`, `document`, `database`; absent is the card), `styleAttributes.border` (`dashed`, `dotted`,
    `invisible`) and `styleAttributes.textAlign` (`center`, `right`). A rectangle is a card with centred text.
  - free text: a text node with an `invisible` border, as big as its text at its `fontSize`.
  - a frame (a slide): a group with a `ratio` (16:9); `metadata.startNode` is the first slide.
  - a sticky note: a coloured text node with `styleAttributes.sticky` (Loam's; other apps keep it).
- A table is a text node whose text is one GFM table and nothing else.
- A drawing (pen strokes, a free line or arrow) is a text node with an `invisible` border whose text is an inline
  SVG: `data-loam="ink"` or `"line"` on the `svg`, a `viewBox` of the node's size, one `path` per stroke. Strokes are
  quadratic curves through the middles of their points, the points being the control points, so Loam reads them back
  exactly; colours are written as `#RRGGBB` with the preset in `data-color`, no colour as `currentColor`.

## How Loam writes it

- As Obsidian does: tabs, one node or edge per line, keys in the spec's order. Changing a card is a one-line diff.
- Fields Loam does not know (another app's extensions, such as Advanced Canvas's `styleAttributes`, `zIndex` or
  `metadata`) and node types it does not know are kept and written back where they were.
- A board is written only when it changed. A board that does not parse is never rewritten.
- When a note moves or is renamed, every board showing it follows (the `NotesMoved` event).
- A note knows its boards: the Backlinks groups of a note's Info list them under "On boards" (the `note-boards`
  service), and `canvas.list path=<note>` answers the same.
- Importing an Obsidian vault keeps its boards: card paths follow the import folder, wikilinks in text cards become
  standard links.

## What a card shows

- Free text: its Markdown with no card round it. A shape: its outline, its text in the middle. A sticky note: a
  square of solid colour. A table: a grid with a coloured header. A drawing: its strokes, which alone take clicks.
- A mindmap note (a view type that `sizesToContent`): the map itself at the board's scale, with no card round it; the
  card is the map's size and moves as the map grows (`ViewContext.contentBounds`), so a board holds several maps.

- A text card: its Markdown (headings, lists, tasks, quotes, bold, italic, code, links) at its own font size,
  wrapped to the card. Double-click or Return writes in it; the card grows when the text no longer fits.
- A note: its title and first blocks. Double-click opens it beside the board.
- A note meant for another view (a mindmap note, a Kanban note: the view type that `prefers` it): that view, live.
  Double-click enters it (it takes clicks, keys and scrolling); a click on the board leaves it.
- A board: a thumbnail of it. Double-click opens it in place of the current one.
- A picture: the picture. A PDF, a video or a sound: the viewer of the `file-viewers-ui` plugin, in the card, which
  answers clicks once its card is the one selected. Any other file: its name.
- A web address: a preview, as Notion and Whimsical show one: a YouTube or Vimeo video with its picture, title and a
  play button (double-click plays it in the card), a post on X with its text and author, a PDF with its name, a page
  with its picture, site, title and summary (Open Graph). Previews are fetched once and kept in the user's caches
  folder, never in the vault; double-click browses the page in the card, a click on the board leaves it.

## Big boards

A board is AppKit (`BoardCanvasView`, docs/APPKIT.md): every card is a layer drawn once into a bitmap off the main
thread, under one world layer whose transform is the camera, so panning and zooming set one transform. Far out
(under 35 %) cards are drawn as tinted paper with their title, a small copy of a picture, strokes; they are drawn
again for the zoom once the camera rests. Live views (PDF, video, a Kanban note, mindmaps) exist only for the cards
near the middle of the view. Arrows are a few shape layers; curves are kept until the board changes.

## Using a board

| | |
|---|---|
| Move around | two-finger scroll or Space-drag or middle-button drag; pinch, the mouse wheel or ⌘-scroll to zoom; ⇧1 fits the board, ⇧2 the selection, ⌘0 is 100 % |
| Minimap | the map button next to the zoom (or `M`): click or drag in it to go there |
| Add | double-click the board or `T` (free text), `R` `O` `D` (rectangle, circle, diamond; the toolbar has the other shapes and a text card), `S` (sticky note), `F` (a frame round the selection), `N` (note), the toolbar (a table, a mindmap, files, a web page), or drag notes and files from the sidebar or the Finder; paste text, an address, a picture or files |
| Draw | `P` pen (strokes drawn near each other are one drawing), the highlighter, `E` eraser, `L` line, `A` arrow (Shift: 45° steps); colours and widths over the toolbar; Escape goes back to selecting |
| Text | resizing free text or a table from a corner scales its text; the shape menu of the selection bar turns a card into free text, a shape and back |
| Tables | double-click a cell to write; Tab and Shift-Tab go across (a new row after the last cell), Return goes down; the menu adds and removes rows and columns |
| Mindmaps | double-click a map to enter it: Tab adds a topic, Return the next one; a click on the board leaves it |
| Present | ⌥⌘P shows the frames one by one (arrows, Space, a click); Escape comes back |
| Export | the board's menu: the board or the selection as PNG or PDF, the slides as a PDF |
| Resize | a selected card has a handle on every corner and side; ⇧ keeps the proportions (pictures keep them unless ⇧ is held) |
| Align | a card sticks to the edges and middles of the others, with pink guides; hold ⌘ to turn it off; the bar over several cards aligns and spaces them |
| Text size | `A−` `A+` in the bar over a text card, or ⌥⌘− and ⌥⌘+ |
| Arrows | drag from a dot at a side of a card onto another card (onto nothing: a new card); click an arrow to colour it, curve or straighten it, dash it, choose its heads, label it; drag its ends to move them |
| Copy | Option-drag moves a copy; ⌘C and ⌘V copy cards between boards |

The motion (a card pops in, lifts when dragged, an arrow draws itself) uses the named springs of `BoardMotion`.

## Commands

Every edit of the board view is also a command, so an agent builds a board the same way.

| Command | Arguments | Does |
|---|---|---|
| `canvas.new` | `folder`, `title` (optional) | creates an empty board (in `Inbox/` by default), returns its path |
| `canvas.list` | `path` (optional) | every board, or the boards with a card showing that note |
| `canvas.read` | `path` | the board's JSON |
| `canvas.add-node` | `path`; `text`, `file`, `url` or `type=group` + `label`; optional `color`, `x`, `y`, `width`, `height`, `near` | adds a card at a free spot (beside `near`), returns its id |
| `canvas.update-node` | `path`, `id`; any of `text`, `file`, `url`, `label`, `color`, `fontSize`, `x`, `y`, `width`, `height` | changes a card |
| `canvas.connect` | `path`, `from`, `to`; optional `label`, `color`, `fromSide`, `toSide`, `shape`, `dashed` | adds an arrow, returns its id |
| `canvas.align` | `path`, `ids`; `align` (`left`, `centerX`, `right`, `top`, `centerY`, `bottom`) or `distribute` (`horizontal`, `vertical`) | lines cards up or spaces them evenly |
| `canvas.remove` | `path`, `ids` (comma separated) | removes cards or arrows, and the arrows of removed cards; the notes stay |
| `canvas.add-frame` | `path`; `ids` (frames them) or `x`, `y`, `width`; `label` | adds a 16:9 frame (a slide), returns its id |
| `canvas.slides` | `path` | the slides' ids and labels in presentation order |
| `canvas.export` | `path`; `format` (`png`, `pdf`), `slides=true`, `out` | draws the board, the slides one page each, into the vault |

`canvas.add-node` and `canvas.update-node` also take `shape`, `border` and `textAlign`.

```bash
loam --vault /path/to/vault canvas.new title=Trip
loam --vault /path/to/vault canvas.add-node path=Inbox/Trip.canvas file=Projects/Trip.md
```
