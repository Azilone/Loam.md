# Themes

A theme is one JSON file in the vault, `.loam/themes/<name>.json`. It travels with the vault like the notes. The theme
in use is named in `.loam/config.json`:

```json
{ "theme": "Paper" }
```

No `theme` key is the built-in **Dither Green** theme. `"system"` is the system look: macOS colours and fonts, drawn light
(the design is light first) unless `"appearance"` says otherwise. There is
no CSS: a theme sets tokens (colours, fonts, how headings, task boxes and tags are drawn), and every view (the
shell, the editor, every plugin) reads them as `ThemeTokens`, so a theme restyles everything at once and stays calm.
The built-in **Things** theme (Settings > Appearance) uses most keys below: start from it to see what a theme can do.

## Loam's own look

A theme chooses colours, fonts, the editor's text (headings, task boxes, tags) and how round the corners are. The rest
is Loam's, the same in every theme, so the app and every plugin look like one thing whatever theme is on:

- **Print**: square dots of the accent fade in from a corner (the window's top right, cards
  under the pointer), the home page ends on a landscape drawn in dots, and the pictures on cards (folder pages,
  gallery covers) are an ordered dither of `colors.ditherInk` on `colors.ditherPaper`. Pictures in a note are never
  touched, nor the files.
- **Pictures**: actions and empty pages show a drawn object in the accent (`PrintIllustration`), emoji are dithered in
  the accent.
- **Cards** are paper with a hairline that takes the accent under the pointer and a small rise.
- **Small labels** (section titles, dates, counts, tags) are capitals in `fonts.mono`, spaced out.
- **Icons** are drawn in the text's colours; the selected sidebar row is a pill of the accent with white text.

The keys that once chose these (`cards`, `labels`, `icons`, `sidebar`, `decor`, `home`, `images`) are ignored, so an
older theme still opens.

Two more keys of `.loam/config.json` sit on top of the theme, and Settings > Appearance writes them:
`"appearance"` (`"light"`, `"dark"` or `"auto"` to follow macOS) picks light or dark for a theme made for both
(`auto`); a theme made for one keeps it, and without the key an `auto` theme is drawn light. `"accent"` (`"#RRGGBB"`)
replaces the accent. With the system look and no accent, the window uses the design's blue, `#2F62E0`.

Choose a theme in Settings > Appearance, or run `themes.use` with `name` (`"system"` for the system look). Run
`themes.install-examples` (or the Install Examples button) to get `Paper.json` and `Night.json` as templates.

A vault can have its own picture in the sidebar's header: put it at `.loam/icon.png` (or `.jpg`, `.jpeg`, `.webp`, `.heic`).
Without one the header shows Loam's icon.

## Format

```json
{
  "name": "Paper",
  "appearance": "auto",
  "colors": {
    "accent": "#C2410C",
    "text": "#1F2937",
    "secondaryText": "#6B7280",
    "background": "#FBF7F0",
    "separator": "#E5E0D8",
    "codeBackground": "#F2EDE4",
    "link": "#C2410C",
    "marker": "#B8B0A3"
  },
  "dark": {
    "colors": { "text": "#EDE6DA", "background": "#1C1A17", "accent": "#F59E0B" }
  },
  "fonts": { "body": "New York", "mono": "SF Mono", "size": 16 },
  "editor": { "lineHeight": 1.3, "columnWidth": 720 },
  "headings": { "font": "New York", "weight": "bold", "sizes": [1.6, 1.35, 1.15, 1], "rules": [1] },
  "tasks": { "checkbox": "circle", "strikethrough": true },
  "tags": { "shape": "rounded" }
}
```

Every key is optional. What a theme leaves out keeps the system's look, so `{ "colors": { "accent": "#0F766E" } }`
is a whole theme. Keys the app does not know are ignored, so a file written for a newer version still loads.

| Key | Value | Default |
|---|---|---|
| `name` | the name shown in Settings | the file name |
| `appearance` | `"light"` or `"dark"` forces the window into it; `"auto"` follows the system | `"auto"` |
| `colors.accent` | selection, buttons, list markers, task boxes, the caret | the system accent |
| `colors.text` | body text | the system label colour |
| `colors.secondaryText` | quotes, frontmatter, done tasks, secondary labels | the system secondary label colour |
| `colors.background` | behind the editor and the workspace | the system text background (sidebars keep the system material) |
| `colors.separator` | dividers, `---` and the hairline under headings | the system separator |
| `colors.codeBackground` | behind inline code and code blocks | a light system fill |
| `colors.link` | links in the editor | `colors.accent`, else the system accent |
| `colors.marker` | the dimmed Markdown syntax (`#`, `**`, `[[`) | the system tertiary label colour |
| `colors.heading` | headings | `colors.text` |
| `colors.highlight` | behind `==highlighted==` text | a pastel yellow |
| `colors.tagText` | a tag's name | `colors.link` |
| `colors.tagBackground` | the pill behind a tag | `colors.tagText` at 12% |
| `colors.checkbox` | a checked task box | `colors.accent` |
| `colors.checkboxBorder` | the ring of an open task box | `colors.secondaryText` at 60% |
| `colors.quoteBar` | the bar along a quote | `colors.text` |
| `colors.sidebar` | around the pages: the sidebar and the window behind them; a dark one under light pages (as in Ink) draws the sidebars and tab bar in light text, as in dark mode | a shade of `colors.background`, else the system material |
| `colors.ditherInk` | the dots of a dithered picture (see "Loam's own look") | `colors.accent` |
| `colors.ditherPaper` | between the dots of a dithered picture | `colors.background` |
| `colors.highlightText` | the text of `==highlighted==` text, over `colors.highlight` | the text's own colour |
| `colors.quoteBackground` | a band behind a quote, from its bar to the column's edge | none |
| `dark.colors` | the same keys, used instead of `colors` when the window is dark | `colors` |
| `fonts.body` | a font family: `"SF Pro"` (the system font), `"New York"` (its serif), `"SF Pro Rounded"`, or any installed family such as `"Georgia"` | `"SF Pro"` |
| `fonts.mono` | the family for code: `"SF Mono"` or any installed one, such as `"Menlo"` | `"SF Mono"` |
| `fonts.interface` | the family of the app's own text: sidebars, tabs, toolbars, cards, menus | `"SF Pro"` |
| `fonts.size` | body size in points, 9 to 40; code is one point smaller | 16 |
| `fonts.letterSpacing` | room between letters of the body in points, -1 to 3 | 0 |
| `editor.paragraphSpacing` | room after each paragraph (blank lines count too), as a multiple of the body size, 0 to 2 | 0 |
| `headings.letterSpacing` | room between letters of headings in points, -2 to 3 | 0 |
| `editor.lineHeight` | line height as a multiple of the font's, 0.8 to 3 | 1.2 |
| `editor.columnWidth` | width of the editor's text column in points, 320 to 2400 | 720 |
| `headings.font` | the family of headings, as `fonts.body` | `fonts.body` |
| `headings.weight` | `"regular"`, `"medium"`, `"semibold"`, `"bold"` or `"heavy"` | bold for `#` and `##`, semibold below |
| `headings.sizes` | sizes of `#` to `######` as multiples of the body size, 0.8 to 4; a shorter list keeps the default for the other levels | Craft's: 1.41, 1.29, 1.18, 1.06, 1, 1 |
| `headings.rules` | the levels drawn with a hairline under them, such as `[2, 4]` | `[1]` |
| `tasks.checkbox` | `"circle"` or `"square"` (soft corners, as in Things) | `"circle"` |
| `tasks.strikethrough` | whether a done task is struck through; it is dimmed either way | `true` |
| `tags.shape` | `"rounded"` or `"capsule"` | `"rounded"` |
| `shape.corners` | holds every corner of the app (cards, buttons, fields, tabs, pills, pictures) to a largest radius: `"soft"` 6 points, `"square"` 2 points; `"pill"` draws the sidebar's rows and fields as capsules and the pages rounder | `"round"` |

Colours are `#RRGGBB` or `#RRGGBBAA` (sRGB, the last pair is the opacity). Numbers outside their range are brought
back into it. A family that is not installed falls back to the system font.

With `"appearance": "auto"`, give a `dark` block: without one, the same colours serve both appearances. A theme
with `"appearance": "dark"` only needs `colors`.

## Catalogue

The community catalog lists themes anyone can install by id. It lives in the public repository
`Azilone/loam-community`, changed by pull request: `themes.json` lists the themes, and `themes/<id>.json` is each
theme's file, in the format above.

```json
{ "themes": [ { "id": "paper", "name": "Paper", "author": "loam", "description": "Warm paper, light and dark.",
  "version": "1.0.0", "appearance": "auto" } ] }
```

- Settings > Appearance > Community Themes shows each one drawn in its own colours, with Install, then Use.
- `themes.catalog` (optional `query`) returns JSON `[{id, name, author, description, appearance, installed}]`.
- `themes.install` with `id` downloads the file, checks that it reads as a theme and writes `.loam/themes/<id>.json`;
  an existing file is kept unless `force=true`. Then `themes.use` with `name=<id>` applies it.
- An id is lowercase letters, digits, `-` and `_`. `LOAM_THEME_CATALOG` (a URL or a path to a `themes.json`) points
  at another catalog; its themes are read from `themes/` next to it.

## When a theme cannot be used

A file that is not valid JSON, a colour that is not `#RRGGBB(AA)`, or a value of the wrong kind (`"size": "big"`)
makes the theme unusable: the app keeps the system look and Settings > Appearance says which key is wrong. It never
stops the app. Themes are read again whenever something in the vault changes, so fixing the file applies it at once.

## Writing a theme as an agent

1. Write `.loam/themes/<Name>.json` with only the keys you need (start from `Paper.json` after
   `themes.install-examples`). Keep contrast readable: text on background at least 4.5:1.
2. Set `"theme": "<Name>"` in `.loam/config.json`, keeping its other keys, or run `themes.use` with `name`.
3. The open window applies it within a second. If nothing changes, read the error in Settings > Appearance (or
   the answer of `themes.use`).

## For plugin authors

Read `@Environment(\.themeTokens)` (`accent`, `text`, `secondaryText`, `background`, `separator`, `codeBackground`,
`link`, `marker`, `bodyFont`, `monoFont`, `bodySize`, `lineHeight`, `columnWidth`, `style`, `spacing`) instead of hard-coding
colours or fonts, and `theme.danger` / `warning` / `success` for status. A theme never changes a page's layout or its
type sizes: those are the app's ([UI-RULES.md](UI-RULES.md)).
Views drawn with AppKit can read `palette` to tell a colour the theme sets from a system default, as the editor does.

### Pictures and sidebar icons for a plugin

- `PrintIllustration(symbol: "my.symbol")` is the picture for any SF Symbol: Loam's own drawing for the symbols it
  knows, otherwise the symbol inked on a stippled tile in the accent. Use it for an empty page or an action tile.
- `PrintIllustration.register("my.symbol") { context, ink in ... }` gives a symbol a drawing of the plugin's own, on a
  100 x 100 board; `PrintIllustration.paint(path, in: &context, ink: ink, seed: 1)` paints a shape as Loam's pictures do.
- `SidebarGlyph.register("my.symbol", outline: "<svg path>", fill: "<svg path>")` gives a sidebar row a glyph in the
  sidebar's manner (paths on an 18 point grid). Without one, the SF Symbol is shown with the same lift under the pointer.
