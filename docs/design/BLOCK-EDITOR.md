# Block editor: the page holds no Markdown

Replaces [CLEAN-RENDER.md](CLEAN-RENDER.md). The note stays a Markdown file; the text the person edits is the page,
not the file. Notion and Craft feel solid because there is no syntax in what you type into: a caret, a selection or
a delete key can only ever meet visible text. Loam gets that the same way, and keeps plain Markdown on disk.

## Why the old editor kept breaking

The text view's storage was the file. `**`, `#`, `- [ ] `, link destinations, code fences, blank lines and the YAML
frontmatter were in it, hidden with a 0.01 pt font (`MarkdownTheme.concealed`). One spot on screen was then several
offsets in the text, and every click, arrow key, delete, selection, highlight and copy had to guess which one
(`HiddenSyntax.snap`, `deleteBackward`, `balanced`...). Each case missed was a bug: a click under the title put an
invisible caret before the frontmatter's `---`, and the next letter broke the YAML; blank lines were real empty
lines you could click into and highlight; a moved block left a blank line behind. Patching a case added another
special case. Removing the hidden characters removes the whole class.

## The model

```
file (Markdown)  --parse-->  NoteDocument  --build-->  text storage (visible text + attributes)
file (Markdown)  <-write---  NoteDocument  <-read---   text storage
```

- **`NoteDocument`** (Foundation and swift-markdown only, `App/Sources/MarkdownEditor/Blocks/`): the frontmatter as
  written, then a flat list of `NoteBlock`s, then what follows the last block. Containers are flattened as Craft and
  Notion do: a list item, a quote line or a callout line is a block with a depth, a quote level and a callout kind,
  not a tree.
- **`NoteBlock`**: a kind (paragraph, heading, bullet, numbered, task, code, table, divider, embed, raw), its
  context (list depth, quote level, callout), its content (`InlineText`: the visible characters and their marks),
  the lines before it that belong to no block (blank lines, a lone `>`, reference definitions, comments), and its
  own lines **as written**.
- **`InlineText`**: an attributed string with Loam's keys: strong, emphasis, strikethrough, code, highlight, link,
  tag, and the HTML marks Markdown has no syntax for (`<u>`, `<sup>`, `<sub>`, `<kbd>`); anything else that has no
  visible text of its own (an inline image, a date pill with a calendar marker and an ISO date, inline HTML) is an atom: one `U+FFFC` carrying its
  Markdown, deleted and moved as one character. A soft or hard line break inside a paragraph is `U+2028`.
- **Syntax Markdown reads as text** is an atom too (`InlineAtoms`), written back as it was: a note link `[[Note]]`,
  `[[Note|text]]`, `![[Note#Heading]]` (drawn as a link, a click opens the note of that name), a footnote `[^1]`
  (raised), math `$...$` and a `$$` paragraph (drawn by `MathText`, symbols and scripts, no TeX engine), a comment
  `%%...%%` (nothing; a paragraph of one is hidden like an HTML comment). Text typed with `$`, `%%` or `^[` is escaped.
- **Folds the page draws, the file never says**: a callout written `[!NOTE]-` starts folded, `[!NOTE]+` open, and
  an HTML `<details>` folded unless written `open`; a click on the title toggles it (`PageFolds`, kept per session).
- **The text storage** is the blocks' `InlineText`s, one paragraph each, and nothing else. Each paragraph carries
  its block (`.noteBlock`); inline marks are attributes; the editor draws bullets, boxes, bars, cards, numbers and
  hairlines in the paragraph's margin from the block, never from characters. A table, a divider, an embed or a live
  block is one `U+FFFC` paragraph showing its component.

## Writing the file back

- **What was not edited is written back byte for byte.** A block keeps its source lines and the content they were
  read as; if its content and context are still the same, its lines are written as they were. The lines between
  two blocks are kept when both blocks are still there, still next to each other. So a file opened and saved is
  identical, and an agent's or git's diff shows only what the person changed.
- **An edited block is written in canonical Markdown**: `**strong**`, `*emphasis*`, `~~strike~~`, `` `code` ``,
  `<mark>`, `[text](url)`, `- `, `1. `, `- [ ] `, `> `, fences sized to the code. Characters that would read as
  syntax are escaped, so reading the block back gives the same text and marks (a property test checks it).
- **Gaps are canonical where they changed**: no blank line between items of a list, `>` between paragraphs of one
  quote, one blank line elsewhere. Content that is not visible (reference definitions, comments) is never dropped:
  it moves with the next block that is still there.
- **What cannot be shown is kept, not lost**: raw HTML blocks, footnote definitions, setext headings and anything
  else the page has no component for are `raw` blocks (shown as written) or atoms. View Markdown Source edits the
  file itself.

## Editing

The text view edits the storage natively (typing, selection across blocks, IME, spelling, find, undo). Structure
is a few explicit operations on paragraphs, each a pure function with its tests:

- Return splits a block (a list continues, a heading's next line is a paragraph, Return on an empty item outdents it
  or ends the list); Shift-Return inserts a line break in the block.
- Backspace at the start of a block turns it into a paragraph, then merges it into the block above. Tab and
  Shift-Tab change a list's depth.
- Typing a shortcut at the start of a block changes its kind, as in Notion and Craft: `# `, `- `, `1. `, `[] `,
  `> `, ```` ``` ````, `---`. Typing `**text**` makes it strong. The characters typed are replaced by the style.
- After each edit the paragraphs are normalized: one block per paragraph, a new block for a split paragraph, the
  first block's kind when two merge.
- Paste reads Markdown (or rich text) into blocks; copy writes the Markdown of the selection and the page as RTF.

The frontmatter and a first `# heading` saying the title are never in the storage: fields under the title edit the
frontmatter (`FrontmatterEditor`), the title field renames the note.

## Status

Each step lands green (`make test`).

1. Built. `NoteDocument`: parse, write, and the round-trip tests (every fixture and every note of a local test vault
   written back byte for byte; random blocks and random marked text read back the same, `LOAM_FUZZ_ROUNDS` for a
   longer run). No UI.
2. Built. Storage: `NoteDocument` to an attributed string and back, the paragraph normalization, the editing
   operations (Return, Backspace, Delete, Tab, shortcuts, marks) as pure functions with tests (`BlockEditingTests`).
3. Built. The block editor, in `BlockSession`, which `EditorController` hands its changes and keys to: rendering from
   block attributes (`BlockStyling`, `BlockDrawing`), typing and saving, the keys and the shortcuts, the title and
   the frontmatter kept out, changes from outside (an agent, a plugin, a field) replacing only the blocks that
   differ, the `/`, `@` and `[[` menus, the format bar, Cmd-B/I/K, copy and paste (Markdown read into blocks),
   `insertAtCaret`, dropped files, the outline's lines; tables (`BlockTables`), pictures and players
   (`BlockEmbeds`), diagrams and collections as components edited on the code page (`BlockComponents`); handles,
   moving blocks and folds (`PageBlocks`); View Markdown Source. `BlockEditorTests` drive the real text view.
4. Built, with one part left. The block editor is the default (`LOAM_BLOCK_EDITOR=0` or `defaults write <app> LoamBlockEditor
   -bool NO` brings the old one back). Not removed yet: the old editor's rendered mode
   (`HiddenSyntax`, the concealed attributes, the span reveal) and its tests; the styler stays for View Markdown
   Source.

## Rejected

- Keeping the hidden syntax and fixing cases one by one: the cause stays, so the bugs keep coming.
- A web editor (ProseMirror, TipTap) in a web view: solid, but not native, and every component (tables, diagrams,
  embeds, collections, the format bar) would be rebuilt in JavaScript.
- A block per text view (Craft's own approach): selection across blocks, find and accessibility would have to be
  rebuilt. One text view with block paragraphs gets them from AppKit.
- A store of our own (a database, block ids in the file): the vault stays plain Markdown for people and agents.
