# Craft as a design reference

Loam's interface takes its cues from Craft, a note app close to ours whose UI we admire, rather than starting from
nothing. Craft is a reference for layout, spacing and behaviour; Loam draws its own views and uses no Craft code or
assets. Its features are not the goal: plain Markdown files stay the format.

## What Craft does (the reference)

- **Window:** one light grey (`#F2F2F1`) behind everything, no gradient. Loam departs from Craft here: in the main window the grey is a veil over the blurred desktop (macOS 26), the pages stay opaque; opaque again with Reduce Transparency.
- **Sidebar** (on the grey, no border): the space (badge + name), "New Document", a navigation group (All Docs,
  Tasks, Calendar), then sections with semibold grey titles (Starred, Folders, Tags). Rows ~34 high, outline icons,
  the selection a neutral grey fill.
- **Tabs** in the title bar row, next to the sidebar toggle and a Home button; the selected tab a white capsule.
- **Page:** the document is a white rounded card detached from the grey, with its own toolbar on top (back, new;
  Share, Aa, inspector), a centred column of text, a large bold title over a hairline.
- **Folder view:** documents as a grid of preview cards on the grey, with grid/list toggles and sort.
- **Inspector** on the right (Insert, Format, Style, Info): the page shrinks next to it.
- **Assistant** as a floating button at the bottom right.

## Done

- Flat grey window (`Glass.lightCanvas`), white selected tab, neutral sidebar selection.
- The right sidebar is the inspector (`InspectorColumn`), as Craft's and Bear's: a segmented control of short tabs (a
  lone tab is a title), each a column of titled groups over white cards, tiles and large figures. A note has
  Outline, Links, Stats (Bear's figures) and Insert (the `/` menu's blocks as tiles);
  a daily note adds Day (calendar, due tasks); a mindmap has
  Style, a graph Graph (folders, most linked), a collection View (group by, fields, sort), a board Board (the
  selection's colour and alignment). Nothing the page already shows, nothing empty.
- The page's own toolbar (`PageToolbar`): Back (each tab remembers what it showed, for the session), New (a glass menu: Note, then the kinds plugins add), and
  the right sidebar toggle in the last pane.

- The editor shows no Markdown: the page is blocks with no syntax in their text, the file stays Markdown (View
  Markdown Source, ⇧⌘U, shows it on request: see [BLOCK-EDITOR.md](BLOCK-EDITOR.md));
  bullets, round checkboxes, quote bars and dividers drawn in its place; a hairline under each title.

- The page's title is the note's name, above the text and edited in place (a rename); a first `# heading` saying
  the same is hidden, and so is the frontmatter, shown as a properties panel under the title. The text scrolls under the toolbar's glass, which then
  shows the name and folder. Craft's spacing: list text 22 points after its marker, room between items, a 1.32 line
  height; focus blocks with a bar, alerts and code blocks on rounded cards (a code block with Craft's line numbers and, under the pointer or the caret, Notion's language menu and copy button: `CodeBlockBar`), inline code as pills, `<url>` without
  its brackets.

- Tables as a component (`TableBlockView`), not styled text: Craft's grid (hairlines, rounded frame, tinted header),
  the blue ring on the active cell, a selection of cells, rows, columns or all of it, a pill on a hovered column's top
  edge and a row's left edge (click selects, a second click opens the menu, drag moves), dots at the right and bottom
  edges that become `+` (add a column, a row), a `⋯` beside the table and a `⋮` in the cell being edited. Keys:
  Tab/Shift-Tab between cells, Return down (a new row at the bottom), Cmd-Return a row, Shift-Cmd-Return a column,
  arrows at a cell's edge, Shift-arrows extend the block, Cmd-A twice selects the table. Menu: "Edit Table" submenu
  (insert, duplicate, move, delete), Align, Cut/Copy/Paste, Reset Column Size, Clear Cell Contents. The source stays a
  plain GFM table the text view never exposes. Where Loam differs: Tab in the very last cell adds a row (Craft wraps
  to the first cell); column widths are kept while the note is open, not saved (GFM has no widths).

- The left sidebar: a "Search" field that opens ⌘O, the navigation rows plugins add with `context.addSidebarLink`, then the sections
  plugins add with `context.addSidebarSection` (Favorites, Folders, Tags, Recent), folded from their title. Folders
  lists the first five top-level folders, then "N more folders"; notes at the root are in All Notes only. The bottom
  bar holds Settings, Recently Deleted, Help and "Customize" (Notion's), which turns the sidebar into cards with a
  grip and a switch to order and hide rows and sections, plus "+ Section from a folder or tag" (a pinned section of
  that folder's or tag's notes), saved under `sidebar` in `.loam/config.json`. A link can carry a count (open tasks).

- Folder pages: "All Notes" in the navigation, Cmd-click on a
  folder (a new tab) or a folder card opens a grid of cards (title, start of the text) for its subfolders and notes
  (`explorer.folder`). A plain click on a folder in the sidebar only unfolds it: the open note stays (a deliberate choice,
  unlike Craft).

- Tabs in the title bar row, shown even for one tab, sized to their
  titles, the first pane starting with Home (the first navigation link); the empty end of the bar drags the window.

- The format bar over a selection (`FormatBarPanel`, in Liquid Glass): highlight (7 colours, written as `<mark>`),
  bold, italic, strikethrough, code, link; Cmd+B, Cmd+I, Cmd+K do the same. Craft's text gradients, maths,
  mentions and comments are left out: plain Markdown has no place for them.

- Settings: a sidebar of panes on the grey (the vault's badge,
  Appearance, Sidebars, Shortcuts, then All Plugins and one row per plugin with settings, About at the bottom), the
  pane as a white page with Back and a breadcrumb on sub-pages, a centred column of titled light grey groups. Each
  plugin is a row (icon tile, name, one line, switch) opening its own page: a "Use …" switch, its settings, its
  permissions and what it needs. Craft opens settings as a tab; Loam keeps the separate window of a Mac app.

- Files in notes:
  dropped or pasted files go into `assets/` and an image link alone on its line shows what it points to, across the
  column, with slightly rounded corners and Craft's caption chip (the alt text); a PDF is Craft's grey card with its
  first page, name, kind and size; a sound a card with a play button and a scrubber; a video the system's player. The
  caret on the line shows the link, and the embed gets Craft's selected-block ring in the accent.

- Collections: the name with its tools on the right (search, new entry,
  view settings), the views as tabs under it with "+"; the table's "#" and "Aa Title" columns and typed fields, the
  board's tinted columns with a pill and a count and "+" under each, the gallery's cards with a cover. Entries are
  notes of a folder; a folder's collection is a `.base` file, and Craft's Collection block is a ` ```base ` block
  (`/collection`, `/kanban`, `/gallery`) whose entries are the notes with `collection: <its note's name>`.

- A field's menu (its table header, or its "…" in the view settings): Rename, Hide, Type, Delete. Deleting asks
  first, takes the field out of the `.base` and of every view, optionally erases its value in the notes, and offers
  Undo for a few seconds. A collection has no switcher in the page toolbar: its views are its own tabs.

- The graph view ([vault](../screenshots/graph-view.png)): the canvas fills
  the page like a Craft page, with the title top left and one rounded bar top right: a tag filter (with the tags to
  pick from) and a single options button (notes without links; distance, for a local graph). No toolbar strip, no
  list mode, no zoom buttons (scroll and pinch zoom; one round button brings the whole graph back). Notes grow in,
  the highlight under the pointer eases in and out, and the camera glides when a filter changes the graph.

## Next

- Craft's arrangement of several pictures in a row (its justified grid), its Small / Regular / Card layouts for a
  file, and the document sidebar's Attachments tab (Media, Links, Files).

- The inspector's Format tab (text style and inline formatting of the selection).
