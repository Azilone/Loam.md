# Clean render: the page shows no Markdown

> Superseded by [BLOCK-EDITOR.md](BLOCK-EDITOR.md): hiding the syntax inside the edited text was the cause of the
> caret, selection and blank-line bugs. The block editor is the default; this page describes the editor it replaced,
> kept behind `LoamBlockEditor = NO` (and used for View Markdown Source).

The note is a Markdown file (precious: agents read it, typing it is fast). The person never sees a syntax character:
not at rest, not under the caret, not in a selection, not in a copy. "The best of both": storage is valid Markdown,
the page looks like Craft or Notion. Showing the Markdown is a choice (View Markdown Source), never a side effect.

## Principle

One text view whose text storage **is** the Markdown. No second model, no round trip, so undo, find, the file and
the agents' edits stay exact. The syntax characters are made to take no room and cannot be reached:

1. **Hidden by attributes, never revealed by the caret.** A hidden character has a vanishing font (`0.01` pt) or
   is drawn by the editor instead (bullet, round box, bar, hairline). Before, the caret or a selection touching the
   syntax turned it back on (Obsidian's live preview). Now nothing does: `SyntaxMode.rendered` is the default and
   `MarkdownTheme.revealing(.rendered)` reveals nothing. `SyntaxMode.source` (View Markdown Source, ⇧⌘U, palette
   "Markdown: view source") shows everything, per editor.
2. **The caret and the selection stay off hidden syntax** (`HiddenSyntax.snap`, applied in
   `textView(_:willChangeSelectionFromCharacterRange:…)`): a caret never rests between two characters of `**`, nor
   before a line's hidden start (`## `, `> `, `- [ ] `), which is where Home goes and where a click lands; an
   arrow key that would not move anything visible goes on to the next visible character. A selection's ends go
   outwards, so what is selected, copied or deleted is whole syntax.
3. **Editing keeps the Markdown valid** (`HiddenSyntax.deleteBackward/deleteForward/balanced`): backspace removes
   what shows, not a hidden character; at the start of a line's text it removes what makes the line a heading, a
   quote, an item (one `>` of a quote at a time); deleting the last character of `**b**` removes the markers;
   deleting or typing over half of `**bold**` or `[text](url)` removes the other marker too (one undo step).
4. **Things that need a value get a component, not syntax.** The frontmatter never shows: as in Craft, only a
   collection's entries have fields, drawn under the title by the Collections plugin (`NoteFieldsView`, a
   `NoteHeader` placed `.underTitle`); edits go back one property at a time through `FrontmatterEditor`, so the
   other lines stay as written. Other notes keep their YAML in the file, seen in View Source. A link's destination is
   typed in a field (`LinkEditorPanel`, ⌘K), not as `](…)`; an existing link opens its field with the remove
   button. Tables, collections, diagrams, pictures and files were already components.
5. **A selection only highlights** (`selectedTextAttributes` has no text colour): macOS repaints selected text in
   its own colour, which drew every character the editor makes clear (a task's `[ ]`, a bullet's `-`, a divider's
   `---`) again. And no system button floats over a selection (`writingToolsBehavior = .none`).
6. **A copy is the page and the file**: `public.utf8-plain-text` is the Markdown, as stored (the note stays
   readable by agents and any tool), and `rtf` is the page as shown (`RenderedCopy`: no syntax, `•` for a bullet,
   `☐`/`☑` for a task, links as links). Pasted into a plain field you get the Markdown; into Notes or Mail, the page.

Rejected: a rich-text (`NSAttributedString`) model with Markdown on save (loses the file's exactness, doubles the
editing logic, breaks the agents' direct edits); drawing everything in custom views (no native text editing).

## Inventory of the leaks (before) and what closes them

Each line has the test that fails without the fix. `CleanRenderTests` drives the real text view offscreen;
`HiddenSyntaxTests` the caret/selection/delete model from the real styler's spans. Rows 8 and 18 are in `EditorControllerTests`, row 9 in `EmbedTests`.

| # | Leak | Cause | Fix | Test |
|---|------|-------|-----|------|
| 1 | Frontmatter as raw `---\nstatus: To do\n---` when selected or the caret went in (screenshots 10, 11) | `concealedOutside` revealed by selection | never shown; fields under the title in collections | `testSelectAllNeverShowsTheFrontmatter`, `testTheCaretInTheFrontmatterIsNotAPlaceToType`, `testTheFrontmatterTakesNoRoomTagsIncluded` |
| 2 | A checked task as `- [x] zd`, the selection spanning a strange zone (screenshot 9) | revealed on selection, then clear characters repainted by `selectedTextColor` | no reveal + highlight-only selection | `testSelectAllShowsNoSyntaxAnywhere`, `testSelectingATodoShowsNoBox`, `testASelectionOnlyHighlightsSoClearCharactersStayClear` |
| 3 | A `base` block as YAML in a code card when Select All reached it (screenshot 8) | `reveals` on any overlap | a block opens only for a caret or a selection inside it (`enters`) | `LiveBlockTests`, `EditorEmbedTests` |
| 4 | A button floating over the selection's start (screenshot 8) | system Writing Tools | `writingToolsBehavior = .none` | `testNoSystemButtonFloatsOverASelection` |
| 5 | `**`, `*`, `` ` ``, `~~`, `[`, `](url)` with the caret inside or a selection over | reveal | no reveal, caret snapped | `testTheCaretOnBoldTextShowsNoMarker`, `testClickingInsideAMarkerPutsTheCaretNextToIt` |
| 6 | `##`, `>`, `[!NOTE]`, `-`, `- [ ]` under the caret | reveal | no reveal, caret goes to where the text starts | `testTheCaretIsNeverBeforeAHeadingsHiddenStart`, `testTypingAtTheStartOfAHeadingGoesInTheHeading` |
| 7 | `---` divider and code fences shown under a selection | reveal + clear colour repainted | as 2 | `testSelectAllShowsNoSyntaxAnywhere` |
| 8 | Date pill turned into its source text (a calendar marker and a date) when selected | reveal | pill stays; View Source shows the text | `testASelectedDatePillStaysAPill` |
| 9 | Image link `![](…)` shown when the caret was on its line | reveal | never; View Source shows it | `testTheCaretOnTheLineNeverShowsTheLinkButViewSourceDoes` |
| 10 | Backslash escapes `\*`, `\#` shown | not hidden | hidden | `testTheRestOfTheSyntaxIsHiddenToo` |
| 11 | `***both***` left a `*` at each end | cmark reports the strong and the emphasis over the same range | inner one inside the outer's markers | same test |
| 12 | Inline images and reference images `![pic](a.png)`, `![alt][r]` fully visible | "an image keeps its syntax" | the alt text, as a link to the file; an image without alt keeps its syntax | same test, `MarkdownStylerTests` |
| 13 | `[ref]: https://…` definitions and `<!-- comments -->` shown | not hidden | hidden (the line with its break) | same test |
| 14 | Backspace next to hidden syntax deleted a hidden character (a `*` of `**bold**` → `**bold*`, markers showing) | native delete | `HiddenSyntax.deleteBackward/Forward` | `testBackspaceAfterBoldRemovesTheLastLetterAndKeepsTheMarkersBalanced`, `testDeletingTheOnlyLetterOfABoldRemovesItsMarkers`, `testBackspaceAtTheStartOfAHeadingMakesItAParagraph`, `testBackspaceAtTheStartOfATodoTurnsItIntoAParagraph` |
| 15 | Deleting or typing over half a style left a lone marker (`ld**`) | native delete | multi-range edit removing the pair's other marker | `testTypingOverHalfOfABoldLeavesNoLoneMarker`, `testDeletingASelectionThroughHalfALinkTakesItsDestination`, `testUndoBringsBackWhatADeleteTookInOneStep` |
| 16 | ⌘K wrote `[text]()` and left the caret in hidden syntax | the destination was typed as syntax | `LinkEditorPanel` | `testALinkIsMadeInAFieldNotByTypingItsSyntax`, `testALinkEditedInTheFieldKeepsItsText`, `testALinkIsRemovedFromTheFieldLeavingItsText` |
| 17 | Copy gave only Markdown (a plain paste elsewhere showed `**`, `- [ ]`, in rich apps too) | plain text view | Markdown + RTF of the page | `testCopyGivesTheMarkdownAndTheRenderedRichText` |
| 18 | The first `# Heading` saying the title showed when blank lines followed the frontmatter | `titleHeading` expected it on the line after | skips blank lines | `testAFirstHeadingSayingTheTitleIsFoundWithTheBlankLineAfterIt` |

## Known, left as they are

- A GFM table without outer pipes (`a | b`) is not parsed by the table component and shows as text. With pipes (what
  every editor writes) it is the component.
- Raw HTML (`<div>`, `<b>`): it is content the page cannot render, so it shows as written (dimmed). Comments hide.
- Footnote definitions (`[^1]: …`) show as a paragraph.
- A `\` hard line break at the end of a line shows its backslash.
- Typing syntax by hand shows it until the pair closes (`**bo` shows `**`): it is what the person is typing. Cmd+B
  with a caret writes `****` with the caret between until the first letter.
- A GFM ordered list's `1.` shows: it is the content's number, as in Craft.
- Fields: only a collection's entries show them (under the title). Other notes' YAML, and keys a collection does not
  have, are edited in View Source or by an agent.

## Where

`HiddenSyntax.swift` (model), `MarkdownEditorView.swift` (`syntaxMode`, `hiddenSyntax`, delete keys, balancing),
`LinkEditor.swift`, `RenderedCopy.swift`,
`MarkdownStyler.swift` (what is concealable), `MarkdownTheme.swift` (`SyntaxMode`, `revealing`, `enters`).
