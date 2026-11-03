# UI rules

Every page of Loam, built in or from a plugin, follows the same layout. A theme chooses **how things look**
(colours, font families, corners, card style, mono labels, decoration). The app decides **where things go and how
big they are**: the rules below, the same for every theme. The pieces live in `PluginKitUI`
(`App/Sources/PluginKitUI/DesignSystem.swift`); using them is the whole rule.

## A page

```swift
PageScaffold("Reading", subtitle: "12 books", width: .reading) {
    Button("Add", symbol: "plus") { add() }.buttonStyle(.press)
} content: {
    ForEach(books) { BookRow(book: $0) }
}
```

- **Title**: `PageHeader`, `.ui(.title)` (28, bold), 16 pt under the page's toolbar (`PageMetrics.top`), its left
  edge on the toolbar's (`PageMetrics.edge`, 32). A theme changes its family, never its size or place.
- **Meta line** (a count, a date) under the title, as a theme label. **Actions** on the title's line, at the right.
- **Content** 20 pt under the header (`PageMetrics.headerGap`), in a centred column: `PageWidth.reading` (760) for
  lists, forms, timelines, settings; `.wide` (1320) for grids, boards, galleries; `.full` for canvases, graphs, maps.
- A page that scrolls its own way keeps the rules with `PageHeader` and `.pageColumn(.reading)`.
- Exceptions, on purpose: Home (an editorial hero in `.ui(.display)`), a note (its title is the note's text),
  canvases, drawings, viewers and mind maps (their title is in the toolbar).

## Scales

| Text (`.font(.ui(.body))`) | Size | Weight | For |
|---|---|---|---|
| `.caption` | 11 | regular | small labels, counts, dates (through `.themeLabel`) |
| `.label` | 12 | regular | secondary lines, hints |
| `.body` | 13 | regular | rows, fields, buttons, descriptions |
| `.emphasis` | 15 | semibold | a row's name, a card's title |
| `.section` | 17 | semibold | a section inside a page, an empty state |
| `.title` | 28 | bold | the page's title |
| `.display` | 40 | bold | a hero |

- **Spacing** (`Space`): 2, 4, 8, 12, 16, 24, 32, 48. No other padding or stack spacing.
- **Radius** (`Radius`, held to the theme's corners): `xs` 4 (tags, check boxes), `s` 6 (buttons, fields, rows),
  `m` 10 (menus, tiles), `l` 14 (cards). Pills are `ThemeCapsule`, never `Capsule`.
- **Fills**: `theme.fillSubtle` (idle field or chip), `theme.fillHover` (under the pointer), `theme.fillStrong`
  (pressed, selected). No other opacity for a fill.
- **Status**: `theme.danger`, `theme.warning`, `theme.success`. Never `.red`.

## Pieces

- `EmptyState("No books yet", symbol: "books.vertical", message: "…", actionTitle: "Add a book") { add() }`: the
  one empty state (a symbol or a drawing as `art:`, a title, one line, at most one action).
- `.buttonStyle(.press)`: the one press feedback. `.hoverFill(radius:)` or `.hoverFill(in:)`: the one hover.
- `.themeLabel(size:)`: every small label (counts, dates, section names); a mono theme sets them in capitals.
- Right sidebar: the `Inspector…` bricks (`InspectorGroup`, `InspectorCard`, `InspectorRow`).

## Never

- `.font(.system(size:))`, `.font(.headline)`, `.callout`, `.caption`: they ignore the theme's interface font.
- Colours outside the theme: `Color.red`, `Color.gray`, `.secondary` where `theme.secondaryText` is in reach.
- A page width, title size or top margin of your own.
