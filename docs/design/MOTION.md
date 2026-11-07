# Motion

Every movement in Loam has a reason: where it comes from, where it goes, and how long it takes are decided here, not
at the call site. The numbers live in code as tokens: `App/Sources/PluginKitUI/Motion.swift`. A surface that needs a
number not in this document adds it here and in `Motion` first.

How this was made: from a read of every `animation`, `transition` and `NSAnimationContext` in `App/Sources`, from
Apple's conventions (Notes, Photos, Music, the system sidebars, popovers and Liquid Glass) and from the Craft app. Motion cannot be seen in a screenshot, and Craft's web app asks for a sign-in: the Craft
values below come from what its screens show (anchors, directions, what is blurred) and from how it feels, not from
frame captures. Rows marked **to check** are estimates, to correct once a frame capture is available.

## Principles

1. **Origin and direction mean something.** What appears grows from what caused it (a card, a button, the caret); what
   leaves goes back to it. A page opened from a card grows from that card; a tab opened after another comes from
   its right; a sidebar slides from its own edge. Nothing fades in from nowhere unless it has no origin.
2. **Spatial continuity.** Moving between two things shows where one is relative to the other: switching to a tab to
   the right shifts content from the right, going back comes from the left. A card moving to another column
   crosses the board, it does not vanish and reappear.
3. **Short springs, settled in a third of a second.** `Motion.Spring.standard` (0.34 s, 12% bounce) is the default.
   Only light, playful things overshoot (`pop`: a checkmark, a toast); pages, sidebars and views replacing each
   other never do (`smooth`, `slide`: bounce 0).
4. **What follows the hand stays under the hand.** Dragging, resizing and scrolling are 1:1 (`Motion.follow`, an
   interactive spring that never lags). Only the release is soft (`settle`), starting from the speed of the hand.
5. **Leaving is faster than arriving.** Arrive with a spring, leave with a 0.12 s ease-in fade (`Motion.exit`): the
   user is already looking at the next thing.
6. **Interruptible, never blocking.** Every animation can be reversed mid-flight (SwiftUI springs and additive
   Core Animation springs do this by themselves; never use a fixed-duration keyframe where the user may act
   again). Input is never ignored while something moves: the field takes keys while the palette is still
   growing; a card stays clickable while it settles.
7. **One thing moves at a time.** A change moves the thing that changed and its neighbours' room, not the whole
   screen. Cascades (`Motion.stagger`) are 30 ms apart, at most 240 ms in all, and only for the first items.
8. **Quiet by default.** No animation on typing, on every keystroke's result, or on scroll position. Hover is a 0.12 s
   colour/shadow change; only cards and big targets also lift.
9. **Reduce Motion means fades, not nothing.** With the system option on, movement, scale, rotation, parallax and
   cascades go; opacity and colour changes stay, at 0.12 s (`Motion.fade`). State must stay readable: a toggled
   checkbox still changes colour. Code reads `@Environment(\.accessibilityReduceMotion)` or uses
   `.motion(_:value:)` / `.motionTransition(_:)`, which do; code outside views uses `Motion.reduceMotion`,
   `Motion.resolved(_:)` and `Motion.appKitDuration(_:)`.
10. **Off the main thread when it is big.** Large moves (sidebar columns) run on the render server (Core Animation
    additive spring, as `SlidingColumnView` does); do not animate a layout that reflows text on each frame.
11. **Sound is not motion, haptics are.** `Haptics` (`PluginKitUI/Haptics.swift`) taps the trackpad when something
    gives way under the hand: `levelChange()` when a block, a table row or a card is picked up; `alignment()` for
    each drop slot, heading tick, split position or folder passed, and when a dragged thing is put down.
    Today: editor blocks and table rows, outline ticks, kanban cards, mindmap topics, tab and split
    drops, folders in Files, Customize cards, split dividers. Never ordinary hovering, never a plain click.
12. **A sound when something lands, never while it moves.** `Sounds.play(.cue)` (`PluginKitUI/Sounds.swift`) names
    the moment; the Sounds plugin (`SoundsUI`) picks a short, quiet sound, and can be turned off (its setting, or the
    Mac's "Play user interface sound effects"). Today: a task or habit checked (`done`) or unchecked (`undone`), a
    note or folder made (`created`), trashed, restored, deleted for good, a block, table row, card, tab or note
    picked up and dropped, a path, code or table copied, an error toast (`failed`), a recording started and done, text
    highlighted (`highlighted`, a marker's stroke played with the stroke drawing itself).
    Never typing, hovering, scrolling, opening a menu or passing a drop slot.

### Token cheat sheet

| Token | Value | Use |
|---|---|---|
| `Spring.tap` | 0.20 s, bounce 0 | toggle knob, selected segment, small control feedback |
| `Spring.standard` | 0.34 s, 0.12 | things changing place or size: cards, rows, tabs, columns |
| `Spring.smooth` | 0.40 s, 0 | a view replacing another, a page opening, a field opening |
| `Spring.slide` | 0.50 s, 0 | side columns in and out |
| `Spring.pop` | 0.30 s, 0.28 | checkmark, toast, badge: light things arriving |
| `Spring.overlay` | 0.28 s, 0.10 | popover, menu, palette, format bar arriving |
| `Spring.lift` | 0.30 s, 0.18 | card rising under the pointer and returning |
| `Spring.settle` | 0.30 s, 0.28 | divider or dragged card falling onto a position |
| `Motion.follow` | interactive, 0.16 s, 0.9 | what tracks the pointer (drag, tilt, pan) |
| `Motion.hover` / `fade` | ease-out 0.12 s | colours, highlights; reduce-motion replacement |
| `Motion.crossfade` | ease-out 0.16 s | two pages swapping |
| `Motion.exit` | ease-in 0.12 s | anything leaving |
| `Motion.ambient` | ease-out 0.22 s | glass and translucency changing on large surfaces |
| `Metrics` | enter 0.96, overlay 0.94, press 0.97, toast rise 12 pt, stagger 30 ms (max 240 ms) | distances |
| Page `Metrics` (`NotebookApp/Shell/PageChange.swift`) | page from a card 0.94, replaced page and palette 0.98, view swap 0.99, tab shift 12 pt, sidebar shift 8 pt, pane shift 24 pt | opening, tabs, splits |
| `Metrics` (overlays, `OverlayMotion.swift`) | palette drop 10 pt, palette exit scale 0.98, menu scale 0.97 + rise 4 pt, bar rise 6 pt, toast sink 8 pt, menu exit 0.08 s, scrim in 0.18 s | palette, `/` menu, format bar, toasts |
| `HoverPose.card` | scale 1.02, lift 3 pt, tilt ±1.2°, shadow deepens | All Notes and gallery cards |
| `HoverPose.compact` | scale 1.01, lift 1.5 pt, tilt ±0.6° | kanban cards |
| `EdgeGlass` | band 32 pt, ramp 56 pt, blur up to 14 pt, eased progress | scroll edges |

Reading the tables: **Today** is what the code does now (audit); a row marked **gap** is still to be
done. Reduce motion is written as what the surface does instead.

## Surfaces

### Pages, tabs and panes

| Surface | What moves, from → to | Duration / curve | Reduce motion | Today |
|---|---|---|---|---|
| **Open a note from a card** (All Notes, gallery, kanban card, search result with a position) | The new page fades in over the grid while it settles from 0.985 to 1 at its own centre: a hint of depth, over in a blink. The grid under it stays still. It used to grow out of the clicked card (0.94, anchored at the card): it read as coming from nowhere in particular, and took 0.4 s. **Back** is the reverse: the note fades out while it settles to 0.985, the grid is there at once. | arrive `pageOpen` 0.18 s ease-out; leave `exit` 0.12 s | fade only | done: `OpenOrigin`, `PageChange`, `PageStackView` (Core Animation) |
| **Open from a sidebar row, link or backlink** | No animation: the new note is on screen in the same frame and the old one is gone (Craft swaps a note for another at once; a 0.16 s fade held every note back by its whole length). A caller that passes `OpenOrigin.sidebar(_)` still gets the cross-fade with an 8 pt slide away from that sidebar. | none (`PageChange.replaced`) | same | done: a resource replacing another in a tab with no origin is `replaced` (`PageChange`, `PageTransition` clears the animation) |
| **Open from Quick Open / command palette** | The palette leaves (see palette row) while the page rises in: scale 0.98 → 1 anchored top-centre (where the palette was), opacity. | `smooth` | cross-fade | done when the caller passes `OpenOrigin.palette`; wire it from the palette (item 5) |
| **Open beside** (`placement: .beside`, split) | The existing pane takes its new width at once (laid out once: animating it reflowed its text on every frame) while the new pane's page enters from the edge it opens on: offset 24 pt toward that edge → 0, opacity. | room: none; page `smooth` (no overshoot); the receded page comes back with `smooth` too | fraction jumps, new page fades in | done: the AppKit split (`SplitTreeView`) sets the panes' frames at once and plays the arriving pane's offset and fade as Core Animation springs (`SplitTreeView.arrive`); the page recedes and returns on `smooth` (`PageChromeView.setReceded`: `settle` made the whole page swell past its size on the drop) |
| **Open in new tab** (⌘-click, ⌘T) | The tab grows from its left edge (scale 0.6 anchored leading + opacity) after the selected one, neighbours slide right; the page cross-fades. | tabs `standard`; page `crossfade` | tab fades in place | tabs ok (`TabBar.tabTransition` in `TabStrip`), page fade ok |
| **Switch tab** | The selected capsule slides to the new tab (shared geometry); the page content shifts 12 pt in from the side of the new tab (new tab right of the old one: from the right) while the old one fades; scroll position and caret are restored, never animated. | capsule `standard`; page `crossfade` + 12 pt | cross-fade only | done: capsule `standard`, page direction from the tab order (`PageChange.tab`) |
| **Close tab** | The tab shrinks toward its left edge and fades (scale 0.6, `exit`); the tabs after it slide left; the page cross-fades to the neighbour that becomes selected (the one on the left, then right). Closing the last tab of a split pane collapses the pane: it fades while its siblings take the room at once. | tabs `standard`; pane `standard` | fade only | done: tab shrinks with `exit`; the pane fades while the others take its room at once |
| **Replace in place / Back / Forward** | Same as opening from the origin, reversed: the page shrinks back toward the remembered card, the previous page fades in under it. With no remembered card (a link, a sidebar row) and for Forward, the page swaps at once, as a link does. | `smooth` | cross-fade | done: the leaving page shrinks to the remembered origin (`WorkspaceController.goBack`) |
| **Page toolbar** (title appearing, glass) | The note's title fades in under the buttons with a 6 pt rise when the page title scrolls out of view; the glass behind switches from page white to frosted. | title `smooth` 0.25 s; glass `ambient` | opacity only | ok (0.25 s / 0.2 s); glass is replaced by the progressive edge below |
| **Page toolbar trail** (folders of the page, "Areas › … › nested folder") | Always in the toolbar next to Back and New; it cross-fades when the page changes and a folder darkens under the pointer. When the pane is too narrow the middle folders go first, then the start (`Breadcrumb.candidates`), with no animation. | change `crossfade`; hover `hover` | same (opacity only) | done (`PageToolbar`) |
| **Segmented view switch** (table/board/cards in the toolbar) | The selection capsule slides between segments; the page cross-fades with scale 0.99 → 1 (no origin: it is a swap in place). | capsule `tap`; page `smooth` | cross-fade | capsule 0.2 s `smooth`; page swap done (`PageChange.swap`) |

### Sidebars, splits and chrome

| Surface | What moves, from → to | Duration / curve | Reduce motion | Today |
|---|---|---|---|---|
| **Left / right sidebar show and hide** | The column slides from its window edge (full width, no scale, no fade) on the render server; left sidebar, as in Craft: the pages are laid out once at their new width and move with the column's edge (`SplitTreeView.follow`, an additive spring on the workspace's layer; the last page reaching the window's edge while it opens, `PageChromeView.followSlide`), and the cards of a grid fly to their new columns with the slide; inspector: the same from the other side (`SplitTreeView.follow` cuts the workspace at the column's edge): the pages are laid out once at their new width and only the last page's edge follows the column (reaching past its place while the column comes in, ending short of it while it goes); the window cannot be dragged by its title bar row while a column slides (a movable window makes AppKit recompute its drag regions on every frame); toggling mid-slide reverses from the current position. The toggle icon crossfades. | `slide` 0.50 s (additive `CASpringAnimation`) | column cross-fades in place (0.12 s) instead of jumping | done: Reduce Motion cross-fades the column in place (`SlidingColumnView`); the first tab bar's room for the traffic lights follows the slide sampled from the same spring (`TabBarView.setLeadingInset`) |
| **Sidebar resize handle** | Follows the pointer 1:1. A hairline accent appears on hover. | none; hover `hover` | same | ok |
| **Split divider drag** | Follows the pointer 1:1 (no animation); holding a key position (½, ⅓, ⅔, ¼, ¾) is a `settle` spring plus a trackpad tick; double-click evens the pair out with `settle`; the grip thickens on hover and drag. | follow 1:1; `settle`; grip 0.15 s | no spring: jumps to the position | done: AppKit dividers (`SplitDividerView`), `Spring.settle` through `FractionSpring` |
| **Diagram viewer** (a click on a diagram) | Covers the pane: fades in over 0.18 s while the picture grows from 0.94; zoom steps (Cmd-+/-, Cmd-0, the bar) ease over 0.2 s, pinch follows 1:1; Escape fades it out (0.12 s). "Edit Code" swaps to Craft's code page at once (diagram on top, drawn again 120 ms after typing stops; code below). | ease out; `exit` | fade only, zoom jumps | done: `PictureViewer` |
| **Pane drop target** (dragging a tab or a note onto a pane) | The edge preview grows from the edge toward the centre (the half the page would take): 0 → half over 0.2 s, then holds; leaving shrinks it back. Centre = whole page highlight with a soft ring. | grow `standard`; ring `hover` | preview fades, no growth | done: `DropOverlay` grows from its edge and shrinks back (SwiftUI, in a hosting view over the page only during a drag; the page steps back in Core Animation, `PageChromeView.setReceded`); the "Add left/right/top/bottom split" zones show one at a time: the nearest comes in as the pointer nears it (`SplitZoneLayout.presence`, 110 pt), leaning up to 10 pt towards it, on `settle` |
| **Files tree: folder unfold** | Children cascade out from the folder row: each row fades in and drops 4 pt from the row above with a 30 ms stagger (max 240 ms), no scale (text that grows shimmers); the chevron turns 90° with `tap`, never overshooting (a Mac disclosure does not wobble); fold: all at once, `exit`. | `smooth`, stagger | no stagger, fade | done (`FolderUnfold` on tokens) |
| **Files tree: drop on a folder** | The folder row under a drag takes a light accent fill inside a dashed accent outline, a "+" pops in at its end, a trackpad tick; a closed folder held 0.7 s opens (Finder's spring-loading) so the note can go deeper. | `pop`; unfold `smooth` | fill and outline fade | done (`sidebarRow(isTargeted:)`, `TreeRow`) |
| **Hover rows** (sidebar, tabs, tool buttons) | Fill fades in. No movement. | `hover` | same | done: `Motion.hover` everywhere (selection too) |

### Popovers, menus, palettes and dialogs

| Surface | What moves, from → to | Duration / curve | Reduce motion | Today |
|---|---|---|---|---|
| **Command palette / Quick Open** | The scrim fades to 12 % in 0.18 s; the panel grows from the top-centre (scale 0.94 → 1 anchored top, a 10 pt drop-in) and the field takes the keys at once. Typing does not animate rows; the selection highlight slides between rows (`tap`), and the panel's height follows the result count (`standard`). Closing: panel scales to 0.98 and fades out (`exit`), the scrim after it; focus returns to the caret. Switching tab (Notes ⌘O ↔ Commands ⌘P, by the tabs, Tab or either shortcut) keeps the panel where it is: the old rows stay until the new ones come, then cross-fade into them (`crossfade`) while the height follows (`standard`), the same both ways. | in `overlay`; out `exit` | fade only | ok (`PaletteChrome`, `QuickPickView`): the highlight slides with a matched shape on key moves only |
| **Slash menu** | Child window appears at the caret, anchored top-left (the side nearer the caret): scale 0.97 → 1 and fade, 4 pt below its rest; it flips above the caret when it has no room below and then grows from its bottom-left. Filtering resizes it (`standard`) without moving its top. Closing: fade only, 0.08 s. | in `overlay`; out 0.08 s | fade only | ok (`SlashMenuPanel`, `PanelFade`): window fade + content scale from the corner nearer the caret; the highlight slides; the panel is always off the screen after its fade (timer fallback) |
| **Format bar** (over a selection) | Appears above the selection and unfolds: the capsule opens from a circle at its leading end to its full width while its buttons come in one after the other (fade + 6 pt, `Motion.stagger`), with a 6 pt rise and a fade; follows a changing selection by sliding (never reappearing) when the selection moves within the same block; the highlight colours replace the buttons with a cross-fade while the bar's width animates. Hides on a fade. | in `overlay`; swap `smooth`; out `exit` | fade only | ok (`FormatBar`): grows from the edge nearer the selection, slides to a moved selection, buttons/colours cross-fade |
| **Popovers** (graph options, collection settings) | Native `NSPopover` animation: do not replace it. Their content does not animate on open. | native | native | ok |
| **Menus / context menus** | Native. Do not replace. | native | native | ok |
| **Alerts, sheets, `NSAlert`** | Native sheet slide from the window's top edge. Do not replace. Inline "rename"/"new field" alerts stay native too. | native | native | ok |
| **Toasts** | Rises 12 pt from the bottom edge while fading in; replacing a toast cross-fades (never stacks); sinks 8 pt and fades out; a click or a swipe down dismisses; the pointer over it pauses the timer. | in `pop`; out `exit` | fade only | ok (`PaletteChrome`, `ToastView`, `CommandRunner.holdToast`): one view, a new message changes the capsule in place; swipe down or click dismisses |
| **Settings** | The window is native. Switching sections cross-fades (0.16 s, no movement); toggles `tap` (the knob slides, the track colours at 0.12 s); "saved" checkmarks `pop`. | `crossfade`, `tap`, `pop` | colours only | toggles `tap` (track colour 0.12 s); section switch cross-fades (`SettingsView`); the "saved" checkmark of the appearance pane is still unchanged |

### Cards and collections

| Surface | What moves, from → to | Duration / curve | Reduce motion | Today |
|---|---|---|---|---|
| **All Notes / folder cards** (`FolderGrid`, `NoteCardView`) | Hover: `HoverPose.card`: grows to 1.02, rises 3 pt, tilts up to ±1.2° around its centre toward where the pointer is (dips on the pointer's side, `rotation3DEffect` on y with a light perspective, x at half strength), the ring turns to the accent and the shadow deepens (radius 10 → 18, y 4 → 8). The pointer's position drives the tilt with `Motion.follow`; entering and leaving use `lift` (so it settles back, never snaps). The hovered card is brought to the front (`zIndex`) so scale is not clipped; the grid pads 8 pt so the scroll view does not cut the shadow. Press: scale 0.985 (`tap`), release back to hover. | enter/leave `lift`; tilt `follow`; colours `hover` | ring + shadow colours only; no scale, lift or tilt | ring 2 pt + shadow at 0.15 s only; no lift in `FolderGrid` (the gallery lifts 2 pt) (**gap**) |
| **Cards appearing** (opening a folder, first load) | First 12 cards cascade: from 8 pt lower, scale 0.96, opacity 0, 30 ms apart; later ones appear at once. Cards in the viewport only. | `standard` + stagger | fade, no stagger | **gap** (cards appear at once) |
| **Cards sorted / filtered / added / removed** (masonry, gallery) | Each card slides to its new place (the layout is animatable); added cards `enter`, removed ones fade in place (`leave`) while the rest close the gap. | `standard` | cross-fade | ok in the collection views (`CollectionMotion.layout`); folder grid **gap** |
| **Collection: table** | Rows: `enter` / `leave`; sort header arrow turns 180° (`tap`), rows reorder with `standard`; "add row" field grows from the footer (`reveal`); column resize follows the pointer. | `standard`, `tap` | fade | ok (`CollectionTableUI`), arrow turns without animation (**gap**) |
| **Collection: view switch / tabs** | View tab underline slides to the selected tab (`tap`); content swaps with a cross-fade and scale 0.99 → 1; search field expands from the loupe (width + opacity); the empty state fades in after 0.1 s. | `smooth` | cross-fade | done: `CollectionMotion.reveal` is `Spring.smooth`; the search field grows from its trailing edge instead of sliding in from the toolbar's |
| **Kanban: hover** | `HoverPose.compact` (1.01, lift 1.5 pt, ±0.6° tilt), border and shadow deepen. | `lift` | colours only | ok (`BoardCardView`: `HoverPose.compact`, tilt follows the pointer) |
| **Kanban: pick up and drag** | The card lifts under the hand: scale 1.03, shadow deep, tilts with horizontal velocity (±4° max, `follow`), leaves a ghost in its slot (35 % opacity, dashed outline) and **follows the pointer 1:1 above everything** (not the system drag image). The column under it takes its tint (`hover`); neighbours part to open a gap the card's size at the insertion index as the pointer moves (`standard`, interruptible); near a board edge the board auto-scrolls horizontally, speed ramping with proximity. | lift `lift`; follow `Motion.follow`; gap `standard` | no tilt or scale; gap opens instantly; card still follows the pointer | ok (`BoardDocumentView`, AppKit): the card's ghost is the gap, a copy follows the pointer, the neighbours glide as Core Animation springs; a note dragged out of the board no longer opens beside (cmd-click and the menu do) |
| **Kanban: drop** | The card settles from where it was released into its slot (position, scale back to 1, tilt to 0, shadow down) with the release velocity as the spring's start; the ghost disappears; a trackpad tick on landing; count badges roll (`numericText`). | `settle` | card jumps into the slot with a fade | ok (`BoardDocumentView.release`: a `settle` spring on the copy's layer carries the release velocity; the move is written when it lands; the count cross-fades) |
| **Kanban: move by menu or property edit** (no drag) | The card travels from its old column to its new one across the board (shared geometry on the path), in place of fade-out/fade-in; both columns' gaps open and close. | `standard` | cross-fade | ok (a card keeps its view across columns and glides to its new place; the card menu has Move to) |
| **Kanban: reorder inside a column** | Same as drag; neighbours slide by one card's height. Manual order is a property of the entry (needs a model order field). | `standard` | no slide | ok (the order is the view's `cardOrder`, `CollectionViewModel.moveEntry`) |
| **Kanban: add a card** | "+" turns into the inline field growing down from the button (`enter(from: .top)`); on Return the field *becomes* the card (same frame, shared geometry) and the field row returns to "+"; the column grows (`standard`). | `standard` | cross-fade | ok (the field leaves as the card arrives at its frame, "+" slides down; new cards go last) |
| **Kanban: delete a card** | The card fades and shrinks to 0.96 in place (`exit`, 0.12 s) then the gap closes (`standard`, starting 0.06 s later so the eye follows). A toast offers Undo (reverse: the gap reopens, the card returns). | `exit`, `standard` | fade, gap closes | ok (`BoardView.delete`, `BoardUndoBar`; the toast has no action yet, so the board shows its own Undo) |
| **Kanban: add or remove a column** | New column enters from the trailing end of the board: offset 24 pt + opacity, the board scrolls to it; removed columns fade and the others close in. | `standard` | fade | ok (`BoardView.columnEnter`; removing a column has no command yet) |

### Editor, tasks, graph

| Surface | What moves, from → to | Duration / curve | Reduce motion | Today |
|---|---|---|---|---|
| **Checkbox / to-do** (editor, Tasks, Agenda) | The box fills with the accent from its centre and the checkmark draws in (scale 0.4 → 1, `pop`); the text dims to 55 % and the strike-through line *draws* from left to right over 0.22 s (ease-out); a light haptic. In the Tasks list the row stays in place for 0.5 s (so the check is seen), then moves to Done (`standard`). Unchecking reverses without the pop. In the editor the box is drawn by AppKit: animate it with a short redraw timer (≈ 0.2 s) or a layer, never a layout. | `pop`; line 0.22 s; move `standard` | colour and strike change at once, 0.12 s fade; no pop, no delay before moving | Tasks: mark `pop`, rows move with `standard`, a group's rows fade and drop 4 pt (never slide from the list's top edge); editor: instant (**gap**) |
| **Heading fold / unfold** (editor) | Bear's and Obsidian's fold. The chevron left of the heading turns a quarter (down → right). Folding: what follows the section slides up as one sheet over the body, which fades and shrinks to 0.98 towards its heading; unfolding is the reverse, the sheet slides down to uncover the body fading in. Drawn from two pictures of the page (before, after), so the text is laid out once, never per frame. | chevron `tap`; sheet `smooth`; body fade 0.24 s ease-in out, 0.40 s ease-out in | a 0.12 s fade from the page before to the page after; the chevron turns at once | done (`MarkdownEditor/HeadingFolding.swift`) |
| **Caret scroll into view** (typing near an edge) | Scrolls just enough to keep the caret clear of the margins (160 pt bottom, toolbar + 32 top). Never animates while the user scrolls. | 0.18 s ease-out | instant | ok (`EditorTextView`, 0.18 s through `Motion.appKitDuration`) |
| **Outline ticks** (right edge of a long note) | Ticks near the pointer widen with a smooth magnet falloff (36 pt radius, up to 1.9×); the hovered and current ticks change colour. Hovering opens a card of the headings, growing from the ticks' side (`overlay`), closing 0.18 s after the pointer leaves (`exit`). A click glides the page to the heading (`smooth`'s 0.40 s, eased out), the caret staying put. | `Motion.follow` for the magnet, `overlay` / `exit`, `smooth` | no magnet, card fades, the page jumps | done: `OutlineTicks` (Outline plugin, a `PageOverlay`) |
| **Highlight** (format bar, ⌘⇧H) | Drawn as a felt marker: a band a little thinner than the letters, edges wandering by 0.9 pt, slanted chisel ends, a touch more ink where it starts and lifts, the wobble seeded by the words (stable across edits and launches). Applied, the stroke is revealed left to right, line after line, its cut slanted like the tip, fast then slowing (0.32–0.6 s with the length), with the marker's sound (`highlighted`). | display link, ease-out | the highlight is there at once; the sound stays | done (`HighlighterStroke`, `EditorTextView.revealHighlight`) |
| **Insert / delete block** (divider, table, image) | No movement: text below moves with the edit. Images resizing follow the handle 1:1. | none | same | ok |
| **Graph view** | Layout settles as a force simulation (a few seconds, continuously damped, then stops: never an endless drift); hovering a node dims the rest to 25 % and keeps its neighbours at 100 % (`hover`); selecting recentres the view on it (`smooth` 0.30 s, never zooming more than 15 %); nodes dragged follow the pointer 1:1 (`follow`) and the simulation warms gently; first layout: nodes grow from the centre with stagger; panning and pinching are interactive. | `smooth`, `hover`, `follow` | simulation runs offscreen to its end and the graph appears settled, with a fade; no recentring animation (jump + fade) | simulation + `smooth` 0.3/0.35 s zoom/centre (`GraphView`, `InfiniteCanvas`): reduce motion not honoured (**gap**) |
| **Mindmap, canvas** | Pan and zoom `smooth`; adding a node: it grows from its parent's edge (scale 0.5 → 1, `pop` for the first, `standard` for the layout); drop target highlight `hover`. | `smooth`, `pop`, `standard` | fade | done: tokens (`MindmapModel`, `InfiniteCanvas`), Reduce Motion honoured |
| **Board presentation: next / previous slide** | A classic Push, not a flight across the board: the camera is on the new slide at once; the board moves as one layer from a screen to the right (going back: the left) while the old slide, drawn where it was, is pushed out the other side. Content inside a slide is scaled with it as a whole. | `smooth` | the old slide fades out over the new one (`fade`) | ok (`BoardModel.moveSlide`, `BoardSlideChange`; the push is Core Animation in `BoardCanvasView.updatePresentation`) |
| **Daily notes, agenda** | Week strip: the accent capsule slides from the day left to the day opened (shared geometry); a week turned pushes the old one out (the new week comes from the side of its arrow, clipped to the days' room, so the two weeks never overlap); the agenda adds days with `smooth`. | capsule `standard`; week `smooth` | cross-fade | done (`DailyHeader`, `AgendaView` on tokens) |

### Scroll edges: the glass

| Surface | What moves | Duration / curve | Reduce motion | Today |
|---|---|---|---|---|
| **Top edge of a scroll area** (page, folder grid, collection, lists, sidebars) | Not a switch: a *progressive blur and fade* whose strength follows how far the content has gone under the edge: 0 at the top of the scroll, full after `EdgeGlass.rampDistance` (56 pt), eased (`EdgeGlass.progress`). The band is 32 pt tall; the blur radius goes 0 → 14 pt, the fade to the page colour 0 → ~90 % at the very edge. Under the page toolbar the same effect is the toolbar's glass. | follows scroll 1:1 (no time curve) | a plain fade band, still scroll-driven (no motion in it) | done: scroll views fade their own content (`softScrollEdges`, colour-agnostic, so it works on a sidebar's grey as on a page's white); the editor and the toolbar draw `EdgeGlassBand` (blur + wash of the page colour), the toolbar's blur coming in once the title is under it |
| **Bottom edge** | Same, driven by how much content remains below: full when more than `rampDistance` is left, 0 at the very end. | follows scroll | same | same as above |
| **Cards' own cut** (`cappedHeight`) | A long note's preview fades over its last 36 pt: static, no motion. | none | same | ok |
| **Implementation note** | macOS 26 has the system's own version: `ScrollView.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])` (and `safeAreaBar`, `NSSplitViewItem.preferredScrollEdgeEffectStyle` from 26.1): a real variable blur, scroll-driven, aware of Reduce Motion. Use it first on every SwiftUI scroll view (`softScrollEdges()` becomes a wrapper). For the editor (an `NSScrollView`), check whether the style reaches it; if not, draw the band with a variable blur layer driven by `EdgeGlass.progress` of the clip view's bounds. | | | |

## Rules for implementers

- Take a spring from `Motion.Spring`, a fade from `Motion`, a distance from `Motion.Metrics`. A new number needs a new
  token here first.
- `withAnimation(Motion.Spring.standard.animation)` in model code is fine; in views prefer `.motion(_:value:)` and
  `.motionTransition(_:)`, which honour Reduce Motion by themselves. `Motion.with(_:_:)` does the same for imperative
  `withAnimation` calls.
- Test with System Settings → Accessibility → Display → Reduce motion on and off; check every row of your surface.
  Unit-test pure parts (positions, progress, delays); do not assert on `Animation` internals.
- Check by recording the window (⇧⌘5) and stepping frame by frame: a transition that shows a second state before
  its start (flash), a layout that jumps at the end, or a shadow clipped by a parent is a bug.
- Never block: no `Task.sleep` before a click works, no modal animation, no `allowsHitTesting(false)` while moving.
- Old per-surface constants become tokens when their surface is touched; keep the feel.
- Never `.move(edge:)` for a row or a field inside a list or a bar: it slides in from the container's edge, from
  far away. Use a few points of offset (`-4` for rows) or a scale anchored where it comes from.
- Exceptions on purpose: the Assistant's morph (`CraftStyle`, measured on Craft), the audio cover's bounce
  (Apple Music's) and the onboarding scenes (`IntroUI`, staged once): the cards spread over the welcome from the
  right (`PaperWipe`, 0.7 s); between cards only the words move (24 pt from the side the user goes to, 0.5 s) while
  the capsules grow and the app window stays and crossfades its picture; the migration's line crossfades in place
  (0.35 s). Reduce Motion fades them all.

## Work items, in order of profit

Each item touches its own files and can run in parallel. Item 2 uses the contract of item 1
(`OpenOrigin`, see 1).

1. **Opening, tabs, splits and sidebars (the shell).** Origin-aware page transitions, directional tab switching,
   close/new tab polish, split open/close room, pane drop preview growing, sidebar reduce-motion fade. Creates
   `PluginKitUI/OpenOrigin.swift` (the rect a click came from, `View.opensFrom(_:)`) and adds the optional origin
   to `Workspace.open`. Files: `NotebookApp/Views/PaneView.swift`, `TabBar.swift`, `TabBarView.swift`, `SplitTreeView.swift`,
   `PaneDropZones.swift`, `PaneHost.swift`, `PageChromeView.swift`, `ShellWindow.swift` (`SidebarMotion`), `SlidingColumn.swift`,
   `NotebookApp/Shell/WorkspaceController.swift`, `PluginKitUI/Workspace.swift`, `PluginKitUI/OpenOrigin.swift`
   (new).
2. **Cards: All Notes hover, tilt, cascade, press.** `HoverPose.card` with tilt following the pointer,
   shadow/ring, front ordering, stagger on first appearance, folder-grid sort animation;
   cards call `.opensFrom`. Files: `PluginKitUI/NoteCards.swift`, `Plugins/FileExplorerUI/FolderGrid.swift`,
   `Plugins/CollectionCardsUI/CollectionCardsUIPlugin.swift` (`GalleryCard`), `PluginKitUI/TappableRow.swift`.
3. **Kanban: drag, drop, reorder, add, delete.** Custom drag layer with ghost, live gap, settle, auto-scroll,
   shared-geometry moves and field-to-card morph, Undo on delete, manual order. Files:
   `Plugins/CollectionKanbanUI/CollectionKanbanUIPlugin.swift` (split into new files in the same folder as
   needed), `PluginKitUI/CollectionViewModel.swift` (move to an index, manual order), `PluginKitUI/ResourceDrag.swift`
   only for a new in-board payload.
4. **The glass at the scroll edges.** Scroll-driven progressive blur at top and bottom, native
   `scrollEdgeEffectStyle` first, own variable blur for the editor; the toolbar glass becomes the same effect.
   Files: `PluginKitUI/SoftEdges.swift`, `NotebookApp/Views/PageToolbar.swift` (`ToolbarGlass` only),
   `Plugins/MarkdownEditorUI/MarkdownTabView.swift`, `MarkdownEditor/EditorClipView.swift` (a scroll offset
   publisher, if needed). Call sites of `softScrollEdges()` do not change.
5. **Overlays and feedback: palette, toasts, slash menu, format bar, settings.** Real enter/exit for Quick
   Open and the palette, toast rise/sink with pause and swipe, anchored scale for slash menu and format bar,
   sliding selection highlight, settings section cross-fade. Files: `NotebookApp/Palette/PaletteChrome.swift`,
   `QuickPickView.swift`, `ToastView.swift`, `CommandRunner.swift` (toast timing), `MarkdownEditor/SlashMenuPanel.swift`,
   `FormatBar.swift`, `EditorTextView.swift` (caret scroll duration only), `NotebookApp/Settings/SettingsComponents.swift`.

Further items: to-do checkbox and strike-through (`Plugins/TasksUI/TaskListView.swift`,
`DailyNotesUI/AgendaView.swift`, `MarkdownEditor/LiveBlocks.swift`); graph view (`GraphUI/GraphView.swift`,
`PluginKitUI/InfiniteCanvas.swift`); folding every remaining ad-hoc constant into tokens
(`FilesPanel.swift`, `MindmapModel.swift`, `DailyHeader.swift`).
