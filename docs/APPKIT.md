# Moving the hot paths to AppKit

Goal: every click answers in the next frame (< 16 ms of main-thread work, < 100 ms to a full page) and every scroll
holds 120 fps on a real vault, as an Electron app feels. Measured on a copy of a real vault (557 notes, 665 tasks,
563 attachments), release build, 2026-11-04:

| Action | Now | Where the time goes |
| --- | --- | --- |
| Open All Notes | 250-450 ms (925 ms the first time) | SwiftUI building and laying out one hosting view per card |
| Open a collection gallery | ~285 ms | SwiftUI graph and layout of the `LazyVGrid` cards |
| Open a note | 75-400 ms | the page's SwiftUI tree around the (AppKit) editor |
| Open Tasks | ~70 ms (was 1.1 s) | fixed by a lazy list |
| Scroll All Notes, gallery, Tasks | ~119 fps | fixed by decoding pictures off the main thread |

Our own code is a few percent of those samples: the rest is SwiftUI's attribute graph, layout and commit. Making
SwiftUI views lighter has reached its limit; the fix is to stop using SwiftUI where many views are made at once.

## Where it stands (2026-11-04)

Real clicks on the same vault copy, release build, longest frame after the click (`LOAM_FRAMES=1`), on a machine
under load (load average 6-25):

| Action | Before | After | What did it |
| --- | --- | --- | --- |
| Sidebar row to a page seen before (All Notes, Tasks, a gallery) | 120-300 ms | 8-41 ms | a tab keeps its last three pages alive (`WorkspaceController.keptPages`) |
| Open All Notes | 250-450 ms | ~140 ms, 273 ms the first time in a session | `NoteCardCell` (AppKit) in `CardGrid` |
| Open a gallery | 285-590 ms | ~140 ms | `GalleryGrid` (AppKit) |
| Open Tasks from a note | 1.1 s, then 62-139 ms | 29-55 ms | `TaskTable` (AppKit) |
| Table view of a collection | 400-480 ms, did not scroll | 215-280 ms, scrolls at 120 fps | lazy rows, a cell's menu made on click |
| Galerie → Table of a collection | 215-280 ms (230-350 ms under load 30) | 43-46 ms, scrolls at 120 fps | `TableRows` (AppKit), the gallery leaving no longer measuring its cards for the table's fields, bitmaps in the screen's colour space |
| Open a note from a card | 75-118 ms | 60-106 ms | unchanged: TextKit laying out and drawing the note |
| Sidebar toggle | | 22-26 ms, no late frame | already in budget: step 4 not needed |

Steps 1 and 3 are done; step 2 became the kept pages (a page's own SwiftUI was not the cost, the editor's text
layout is); step 5 is done for the table and the board ("The board"); steps 4 and 6 are in budget
and wait for a measure that says otherwise.

The table (2026-11-04, load 10-15): rows are reused AppKit views (`CollectionTableUI/TableRows.swift`), each drawn
once into its layer (~0.5 ms a row) and edited in place (an `NSTextField`, the options' `NSMenu`, the date picker in an
`NSPopover`); the header, "+ New" and the empty state stay SwiftUI (an embedded table has the same AppKit rows since). Most of the old cost was not
the rows: the gallery being replaced got one more update with the table's fields and measured every card for them
through a hosting controller (~200 ms), and every `CachedDrawingView` bitmap was sRGB, converted pixel by pixel on a
P3 screen when committed (~25 ms). A collection view that is no longer the page's view now ignores that update.

## Animations at 120 fps (2026-11-04, second pass)

A motion runs at the display's rate only when Core Animation plays it: a SwiftUI animation lays its views out on the
main thread for each frame, and a page there costs more than a frame. Same vault copy, release build:

| Action | Before | After | What did it |
| --- | --- | --- | --- |
| ⌘T, frames late during the motion | 14-17 of 16-20 (~35 fps) | 1-15 of 50 | the pages in AppKit (`PageStackView`), the tab's glass an image, the palette in its own hosting view, the home digest off the main thread |
| ⌘W, first frame | 100-200 ms | 15-50 ms | the last page of the last two tabs kept alive |
| A note opened from a card, frames late | all (~22 fps) | 1-5 of 45-50 | the page grows as a layer: its text is no longer drawn again at each step of the scale |

Then: the tabs are AppKit (`TabStripView`, the glass sliding and a new tab growing as layer animations), a side
column is never hidden but moved out of the window (a hidden hosting view held its updates back for the first frame
of its slide), and a page no tab shows any more is reused by the next page of its kind (`PageStackView.spares`: the
home page for ⌘T, the editor for the next note opened from a card, which then only loads the note as a link does).

Then: a card's text keeps its TextKit layout and its drawing at the last widths (a page going back and forth between
two widths, the right sidebar showing for a note and not for the grid, measures nothing again), and the palette fades
in and out as a layer. ⌘T: 2-3 late frames of 55.

Then: what a first-time action would build is built ahead, hidden, while the app is idle (no key, click or scroll for
a second, nothing moving), one page per pass (12-30 ms each): an editor on the last edited note and the home page (the
spares), the page of the first sidebar row (All Notes, `PageStackView.ready`) and the pages of the tabs next to the
shown one (`retained`, which a click on a tab never found for a note: its generation changes with the click). The first
screen of All Notes' cards is read off the main thread at launch (`ExplorerModel.warmAllNotes`). First time in a
session, release build, longest frame, load average 12-30:

| Action | Before | After |
| --- | --- | --- |
| All Notes | ~270 ms | 15-21 ms |
| A note from a card | 70-120 ms | 15-69 ms |
| ⌘T | ~70 ms (home page built) | 39-111 ms, 21-25 ms the second time |
| A tab restored at launch, clicked | its page built (70-130 ms for a note) | 8-10 ms |

A page built ahead has settled before it is shown: All Notes opened the first time does not cascade its cards in.
What is left of the first ⌘T is no page: Quick Open's field taking the keyboard the first time (AppKit loads its
password autofill framework then) and its first layout.

Then: All Notes at a width it has not been at (the left sidebar sliding in, a window resized) measures and draws its
cards off the main thread. A card is placed at once with its texts as tall as at its last width
(`NoteCardCell.provisionalHeight`), measured in the background (`NoteCardCell.measure`, a text stack of its own), then
the grid places the cards again and the ones that moved glide there (an additive `position` animation; none during a
live resize or under Reduce Motion). `CachedDrawingView` draws a new size in the background (`backgroundDrawing`) and
keeps showing its last drawing, top left and unstretched, until it is ready; its first drawing, and one after
`invalidate()`, stays on the main thread, so a card coming into view never shows empty. The masonry is dealt once per
set of cards and column width and only stacked again as heights come in, heights are keyed by a number per note
instead of its path, a card's hover ink is drawn when it is hovered, not at each width, and drawings are made in the
window's colour space and BGRA, which Core Animation shows without converting them at commit. The gallery's text
draws the same way (its heights stay measured on the main thread: its fields are SwiftUI). Same vault copy, release
build, machine under load (load average 20-90):

| Action | Before | After |
| --- | --- | --- |
| Left sidebar on All Notes, to a width not seen yet | 40-110 ms | 8-25 ms (12 widths) |
| Left sidebar, to a width seen before | 22-26 ms | 11-17 ms |
| Live window resize, main thread per step | | 11-17 ms |

Left: one long frame (60-100 ms) when a note opens, as the right sidebar comes and the note is laid out at its width
(see "Opening a long note" below);
the first slide of the left sidebar in a session (~50 ms, wherever it is: the sidebar's own first layout).

## The other screens (2026-11-04, third pass)

Same vault copy, release build, measured on a machine under load (load average 10-60: other agents building), so
the main thread's own time (`sample`) decides, not the frame times alone:

| Action | Before | After | What did it |
| --- | --- | --- | --- |
| Open a folder of 35 notes in the sidebar | 18 of 18 frames late, 73 ms | 2-4 of 57 late, 17-33 ms | `FolderTree` (AppKit): the rows' layers slide on the render server; SwiftUI hit-tested every row for the hover at each step of the slide (45% of the time) and laid the section out |
| Open or close a small folder | 1-3 late, 16-25 ms | same | already in budget |
| Drop a card on a board of 110 cards | 160-650 ms frame | ~155 ms frame | the file tree's refresh (~55 ms, twice) read off the main thread (`ExplorerModel.refreshSoon`), the habits board refreshes only for its own notes |
| Drag a card | 1-6 late a second, 35-59 ms | same | ~3 ms a frame on the main thread: the late frames are the machine's load |
| Quick Open, typing | 8-13 ms a key | unchanged | in budget |
| Search popup, typing | 12 ms a key, the main thread idle | unchanged | in budget: the search runs off the main thread |
| Note switch, chrome (fields, outline ticks, backlinks) | ~2.5 ms of a 50 ms switch | unchanged | the rest is the editor (TextKit), not the chrome |

`ExplorerModel.refresh` ran on the main thread at every `VaultChanged`, so at every autosave: two walks of the disk
(`files.tree()`, `vault.stamps()`) and a sort of every note for the five recent ones, ~55 ms on 600 notes. The
listeners now call `refreshSoon` (read in the background, refreshes asked meanwhile make one, an older read is never
applied over a newer one); the model's own actions still `refresh` at once.

Left: dropping a card still costs ~100 ms in one frame, when nothing moves: `CollectionViewModel.reload` of every open
collection on each `VaultChanged` (~25 ms each, twice per drop: the note's field and the view's order are two
writes), `TaskBoard.refresh` (~23 ms). The board's first opening takes 250-400 ms (SwiftUI building 110 cards). Both
done in "The board" below.

Measuring: an agent instance with `LOAM_FRAMES=1` stops drawing when the display sleeps (no frames, clicks change
nothing on screen): keep it awake with `caffeinate -u -d`. `loam-ctl ax` and `hit` turn the accessibility tree on for
the rest of the run, which costs SwiftUI ~10% more per frame. A board's cards take scripted drags since the board
accepts window-activation clicks (`allowsWindowActivationEvents`).

## The board (2026-11-05, step 5)

The collection board (`CollectionKanbanUI`) is AppKit: `BoardScrollView` through `makeNSView`, the same view in a
page and in a note. Its cards are reused views alive near the screen only (`BoardCardView`: the title a
`CardTextView`, the fields and checklist drawn once into a layer by `BoardCardDetails`), the columns hand-placed
(`BoardPlacement`, numbers only, tested) in a scroll view that now scrolls down too (the SwiftUI board cut a tall
column). The drag is the board's own mouse handling: a copy of the card follows the pointer, set at each event; the
neighbours glide to the gap as additive Core Animation springs; the drop is a `settle` spring on the copy's layer
carrying the hand's speed; hover, lift and lean are the card's `sublayerTransform`; Reduce Motion drops them. The
SwiftUI board is deleted.

Collections read off the main thread: a change on disk calls `CollectionViewModel.reloadSoon` (the read on a
background thread, refreshes asked meanwhile make one more, an older read never applied over a newer one), and only
for the collections it can change (`isAffected(by:)`: its `.base`, its block's note, a note under its home folder).
A drop shows the move at once from what was written (`moveEntry` updates the result itself) and writes on the next
turn of the main thread. The note graph takes a lock for that (`NoteGraphIndex.state`). On the way, every save's
listeners got lighter, since a drop is two saves: `note-query` keeps its stamps up to date file by file instead of
walking the vault again (an open note looking for its collection paid that walk, ~25 ms), a note's collection is
forgotten only when it or a `.base` changed, the tags and the task list read in the background, a date pill no longer
makes a `DateFormatter` per card.

Same vault copy with a board of 110 cards (4 columns, dates, checklists), release build, 1300 x 850. "Before" is the
SwiftUI board measured with the screen on (`LOAM_FRAMES=1`, longest frame); the screen was locked for "After", so
both builds were also measured with the main thread's time after each input (`busy` lines, below), load average 5-25:

| Action | Before | After |
| --- | --- | --- |
| Open the board (longest frame / main thread) | 408 ms frame | 29-48 ms of main thread, 115 ms the first time in a session |
| Drag a card, 10 pointer moves | 505-680 ms of main thread (50-68 ms a move: ~15-20 fps) | 11-33 ms (1-3 ms a move) |
| Drop a card, main thread in the second after | 180-191 ms frame; 187-285 ms of main thread | 79-105 ms of main thread, longest turn 30-49 ms |
| The board's own share of a drop | | ~6 ms (the writes and their listeners) + ~2 ms (the board shown again) |

What is left of a drop is not the board: a SwiftUI calendar illustration (`PrintIllustration`, a kept page or panel)
drawn again at each change of the vault, AppKit saving the window's restorable state, All Notes kept alive sorting its
cards (`ExplorerModel.cardItems`), `DailyCalendar.refresh` listing the daily notes. And `Sounds.play` starts the audio
device on the main thread: with the screen locked it held a pick-up for seconds. Numbers with the screen on are still
to take (`scripts/perf-ui.py`).

Measuring with the screen locked: the display link gives no frames, so `LOAM_FRAMES=1` also logs, for each input the
driver sends (`open`, `click`, `key`, `press`, `move`, `release`), the main run loop's longest turn and total time in
the second after it (`busy release: longest 32.0 ms, 88.3 ms in 18 turns`). SwiftUI defers its drawing while the
screen is locked, so a SwiftUI screen looks cheaper there than it is: compare AppKit with AppKit, or with the screen on.

## The mindmap (2026-11-05)

The mindmap (`MindmapUI`) is AppKit: `MindmapCanvasView` through `makeNSView`, the same view in a page, on a board's
card and on a folder page's card. SwiftUI made each topic a view (`ForEach(model.scene)`) and drew the edges in a
`Canvas`, so a pan or a zoom laid out and drew every topic again at each frame. Now:

- Each topic is a layer whose body is a bitmap drawn once per look (text, depth, size, branch, theme, pixels per
  point) by `MindmapTopicArt`, on every core, in the window's colour space; selection ring, hover tint and fold toggle
  are layers of their own, so selecting or hovering draws nothing again.
- The camera is the transform of the layer holding the topics and the edges: a pan or a zoom sets one transform.
  The topics are drawn again sharper (or lighter) in the background once a zoom settles past 100 % or 200 %.
- The edges are a few shape layers, one per colour, width and shade: each curve cut in four pieces getting stronger
  toward its topic (`MindmapEdgeStyle`). The dot grid is two replicator layers.
- A change of the layout springs each topic to its place (`Motion.Spring.standard`, Core Animation); a new topic grows
  from its parent and a folded one shrinks into it; the edges follow the topics' presentation frame by frame only
  while they move. The camera glides with `Motion.Spring.smooth`. Reduce Motion: no movement, a 0.12 s fade.
- The topic being edited gets an AppKit `NSTextField` in a box scaled as the camera; the keys are the canvas's own
  (`keyDown`, `performKeyEquivalent`, the Edit menu's actions). Drag, drop guides and marquee are the canvas's mouse
  handling and layers. The zoom bar, the read-only banner, the shortcuts and "Note not found" stay SwiftUI in hosting
  views of their own, made once per theme; the inspector's "Style" tab stays SwiftUI.
- Not entered on a board (or on a folder page's card), the view shows a picture of the map drawn off the main thread
  (`MindmapSketch`), and `draw(_:)` gives it to a board's export (`cacheDisplay`).

A map of 297 topics (8 branches of 6 × 5) in a copy of the real vault, release build, 1300 x 850, `LOAM_FRAMES=1`,
machine under load (load average 15-35); pan and ⌘-scroll are trackpad scrolls of 120 events a second
(`loam-ctl scroll … --for MS [--cmd]`):

| Action | Before (SwiftUI) | After (AppKit) |
| --- | --- | --- |
| Open the map, longest main-thread turn | 361 ms (first frame, then a 337 ms one) | 110-135 ms, first frame 15-31 ms; the map's own share ~40 ms (`sample`) |
| Pan, trackpad | 13-18 frames a second, every frame late | 118-120 frames a second, 1-2 late a second |
| Zoom, ⌘-scroll | 5-24 frames a second | 106-119 frames a second, 1-2 late a second |
| ⌘= / ⌘- (animated zoom), first frame | 217-353 ms | 20-130 ms; ~20 ms of main thread in `sample` (12 commit, 6 the zoom bar's label) |
| ⌘0 (fit), first frame | 120 ms, then 233 ms | 7-12 ms, no late frame |
| Tab (a new topic, being edited), first frame | 221 ms (longest turn 320 ms) | 10 ms (longest turn 33-41 ms) |
| Fold, unfold, ⌘↓, undo, first frame | 6-14 ms, a 55 ms turn | 3-15 ms, under 9 ms of main thread |

What is left of the longest turns is not the map: each ⌘ key goes through AppKit's menu lookup and its donation
(`NSIsMenuKeyEvent`, `_donateMenuItem`, ~7 ms), the pages built ahead while idle (`PageStackView.buildAhead`, a
second without input: wait ten seconds after opening a window before measuring, and keep pauses under a second), the
inspector's SwiftUI. Opening a map still measures every topic's text and splits the branches on the main thread
(~18 ms for 300 topics, `MindmapTabModel.init`).

Measuring a canvas: `loam-ctl scroll X,Y DY --for MS` sends trackpad events through the app's dispatch where no
scroll view is under the point (a SwiftUI canvas's event monitors see them) and to the view under it; `--cmd` holds ⌘.

## The whiteboard (2026-11-05)

The whiteboard (`CanvasUI`) is AppKit: `BoardCanvasView` through `makeNSView`, the same view in a page, in a card and
in a test. SwiftUI built a view per card near the screen (`BoardCardView`, glass, handles, gestures) and drew the far
cards and the arrows in `Canvas` passes again at each frame of a pan or a zoom. Now:

- Every card, shape, picture, table, link and drawing is a layer in board units (`BoardItemLayer`) under one world
  layer whose `sublayerTransform` is the camera: a pan or a zoom sets one transform and the dot grid's position
  (`CanvasDotGridLayer`, two replicator layers). Nothing is laid out or drawn again while the camera moves.
- An item's look is a bitmap drawn by `BoardDrawing` from a `BoardItemSpec` read on the main thread, on every core
  (`BoardRenderer`), in the window's colour space, at the zoom's power of two: drawn again in the background when the
  camera rests at another level (or at once when the picture would be more than twice too small). Far out (under
  35 %) a card is a tinted sheet with its title, sized for the screen. What shows nothing yet is drawn at once on all
  cores, so a card never comes in empty; pictures are decoded in the background (the paper shows meanwhile).
- Selection rings, hover outlines, the light under the pointer and the lift of a dragged card are layers of their own
  (`Motion.Spring.lift`, `pop` for a new card); handles, the marquee, the drop ring and the presentation's cut-out are
  layers in view points, moved with the camera. Groups and frames are shape layers with a bitmap label.
- Arrows are shape layers in board units (`BoardEdgesLayer`): one per colour for the still ones, one each for the
  selected, dashed, new (drawn in with `strokeEnd`) and moving ones; only the arrows touching what is dragged are drawn
  again during a drag. Labels are small bitmaps.
- Clicks, drags, keys, scrolling, pinches and drops are the view's own: it finds the handle, card (a drawing by its
  strokes), group border, frame or arrow under the pointer itself. Editors are AppKit (`BoardEditorHost`: an
  `NSTextView` for a card, `NSTextField`s for labels and table cells), placed over what they write as the camera moves.
- Live cards (a mindmap, a Kanban note, a PDF, a video, a page entered) are views over their cards, only the few near
  the middle once the camera rests (`BoardEmbeds`); a container's bounds in board units scales them, so a pan or a
  zoom moves them without laying them out again.
- The camera's animated moves (fit, ⌘=, the minimap, leaving a presentation) step a `Motion.Spring.smooth` on the
  display's frames (`CanvasCamera.move`), the point staying in place on screen kept there; a fade's ease under Reduce
  Motion. A slide change pushes a picture of the old slide out (`CALayer.render`) while the board comes in.
- The tools (`BoardToolsView`), the zoom capsule (`CanvasZoomControlsView`) and the minimap (`BoardMinimapView`) are
  AppKit, placed by hand, made in the first frame. The selection bar, the ink bar, the presentation bar and the empty
  state stay SwiftUI in hosting views of their own; the first two are made hidden while the board is idle after it
  opens. The export draws the same bitmaps into a PDF or a PNG (`BoardExport`).

A board of 203 items (10 groups, 61 text cards, 25 notes, 15 pictures, 24 shapes, 20 free texts, 10 stickies, 4
tables, 6 drawings, 4 links, 50 arrows, a copy of the real vault), release build, 1300 x 850, `LOAM_FRAMES=1`, load
average 3-6, every gesture from the board's middle (`loam-ctl press/move/release`, about 25 moves a second):

| Action | Before (SwiftUI) | After (AppKit) |
| --- | --- | --- |
| Open, first time in a session (longest frame) | 254 ms (390-540 ms under load) | 132 ms (120-250 ms under load); the board's own work ~60 ms |
| Open again (a kept page) | 17-21 ms | 19-21 ms |
| Zoom in, 7 clicks on +, animated | 50 frames late in 8 s; 400 ms of main thread a click, turns up to 209 ms | 14 late in 8 s; 130 ms a click (the drawing for the new zoom) |
| Zoom out, 7 clicks on −, animated | 64 late, turns up to 240 ms | 1 late, turns under 2 ms |
| Pan, hand tool | 51 then 323 late, frames up to 60 ms | 24 and 22 late, frames up to 21-37 ms |
| Pan, trackpad (120 events a second) | — | 118-120 frames a second, 1-2 late a second |
| Zoom, ⌘-scroll | — | 118-119 frames a second, 1-3 late a second (one second of 15 at the switch to far cards) |
| Drag a card | 14 late, frames up to 36 ms | 2 late |
| Drag all 203 items | 64 late, frames up to 47 ms | 2 late, frames up to 25 ms |
| Draw an arrow | 118 late, frames up to 53 ms | 1 late |
| Type in a card, 20 keys | 27 late | 5 late (main thread under 1 ms a key) |

Trackpad pans and ⌘-scroll zooms could not be sent to the SwiftUI board (its event monitors never saw the driver's
events). What is left of the first opening is not the board: the page and its inspector, and the first glass views
of the session. Left: a note card shown up close the first time reads its note on the main thread
(`BoardStore.file`); the selection bar's SwiftUI is measured once per change of selection.

## The shell (2026-11-04, fourth pass: steps 2 and 6)

The window's root (`ShellWindow`) and the page toolbar were SwiftUI: a whole-window body that read the sidebars, the
first pane's history, the window's title and the page actions, so a note switch or a sidebar toggle evaluated it and
diffed both columns, and each pane's toolbar and Home button were hosting views of their own. Now the root is AppKit
(`ShellRootView`): SwiftUI only hands it the theme. Each part follows what it shows (`Follow`, an observation loop
that runs only on a new value): the columns slide (`SlidingColumnView`), the workspace (`SplitTreeView`), the title bar
row (`ChromeButton`), the window's title, the palette and the key monitor. The page toolbar (`PageToolbar`: Back,
Forward, the trail of folders, the title once scrolled, the view switch) and Home are AppKit. What plugins give stays
SwiftUI in a hosting view of its own: the sidebars' panels and the inspector (`LeftSidebar`, `InspectorColumn`), the
window overlays and the toasts (`OverlayHostingView`, which takes only the clicks on what it draws), the glass behind
the toolbar (`EdgeGlassBand`, the plugins' own scroll edges).

Same vault copy, release build, the old and the new build run one after the other at the same load (load average
3-25), longest frame after the input (`LOAM_FRAMES=1`, median of 7) and the main thread's samples over 16 inputs
(`sample`, 7 s; SwiftUI's attribute graph updates in brackets):

| Action | Before | After |
| --- | --- | --- |
| Left sidebar toggle | 33 ms; 386 samples (207) | 25 ms; 292 samples (95) |
| Right sidebar toggle | 33 ms | 22-25 ms |
| Note switch | 28-29 ms; 439-524 samples (183-226) | 22-29 ms; 383-418 samples (111-131) |
| ⌘W | 26-30 ms | 22-24 ms |
| ⌘T, then Escape | 43-44 ms; ~300-340 samples (~125) | 37-45 ms; same |
| Live window resize, per step | 19-20 ms | 19-20 ms |

A sidebar toggle no longer evaluates SwiftUI outside the column that moves, and a note switch runs the attribute graph
about 40% less. ⌘T is the palette and the home page, both SwiftUI already in hosting views of their own; a resize step
is the page's own hosting view (the editor page's layout), not the shell.

## Opening a long note (2026-11-04, fifth pass)

Same vault copy, release build, each note opened for the first time in the session from All Notes (`loam-ctl open`),
longest frame after the click, two runs each, load average 5-11:

| Note | Before | After | What did it |
| --- | --- | --- | --- |
| Framework d'un business profitable (344 KB) | 675-677 ms | 48-54 ms | the first part read and styled at once, the rest added in 2 ms slices, one per frame |
| Personalize.design (168 KB, 30 pictures) | 1,135-1,227 ms | 49-54 ms | a picture arriving shows the components again, not the whole page restyled (30 restyles) |
| L'offre à 100M $ (136 KB) | 44-173 ms | 69-83 ms | as above |
| Gojiberry (72 KB) | 58-66 ms | 45-47 ms | as above |
| Feuille de route MVP (56 KB) | 54-56 ms | 42-50 ms | as above |
| Typing at the end of the longest note, first frame per key (median) | 6.5-15 ms | 7.4-7.7 ms | in budget; the outline's measure after a pause 20-30 ms → ≤ 10 ms |

- `BlockSession.show` reads only the note's first part (`NoteReader.headLength`: a cut at a blank line before a
  paragraph or a heading, outside fences and comments; none for a note with reference definitions, footnotes or
  `<details>`), as much as the page shows plus a third, and styles it. The whole note is read off the main thread;
  its other blocks are added and styled 2 ms a frame (`FrameTicker`: on the display's frames, since slices queued
  on the run loop ran in the same frame). Their tables and pictures come with them. An edit, a save, a restyle or
  a scroll to a line first finishes the page at once (`finishStyling`).
- The note's text was a bridged string: reading it walked it a character at a time through Objective-C (a third
  of the reading); `NoteReader` makes it native first.
- An embed arriving restyled the whole page: 30 pictures, 30 restyles, 1.5 s. It shows the components again,
  once per turn (`componentsChanged`).
- The outline model reads the headings off the main thread; the ticks are an `Equatable` subview, so the per-key
  scroll changes no longer rebuild them, and they measure from what shows (TextKit's estimate above), not from the
  note's start.
- Placing tables and live blocks (`placedRange`) and the drawn range walked every fragment from the note's start to
  find two points; they walk from TextKit's viewport now.

Left: the frame that shows the note is still 40-80 ms. In it the editor takes 9-20 ms (reading the first part
3-5 ms, replacing the last note's text 4-14 ms, styling 2-6 ms) and TextKit's layout 3-5 ms; a 2 KB note's frame is
21-36 ms with 4 ms of editor: the rest is the page's SwiftUI and the commit (the inspector arriving changes little:
without it the frame was the same). Saving a long note costs one 40-80 ms frame after a pause: the note written
(`currentMarkdown`, ~15 ms), then `VaultChanged` on the main thread: tags (`TagsModel.refresh` reads the vault's
stamps), the note graph (`NoteGraphIndex.apply` parses the note) and `TaskBoard.refresh`.

## One implementation: AppKit for what moves (2026-11-04)

A screen that moves or shows many views at once is AppKit, and only AppKit: no SwiftUI twin is kept for the iPhone
shell, for an embedded case or for tests. A second version is twice the work at each change, drifts from the first
and keeps the slow path compiled and reachable. The tests render the AppKit views.

- **AppKit**: the shell's root, the tabs (`TabStripView`), the pages (`PageStackView`), the page toolbar, the folder
  tree (`FolderTree`), All Notes and folder pages (`CardGridView`, `NoteCardCell`), the gallery (`GalleryScrollView`),
  the collection table's rows (`TableRows`), the task list's rows (`TaskTable`), the collection board
  (`BoardScrollView`), the mindmap (`MindmapCanvasView`), the whiteboard (`BoardCanvasView`). A gallery, a table or a board in a note (a `base` block) is the same view as in a page, as
  tall as its content up to the block's limit.
- **SwiftUI, one version**: settings, onboarding, dialogs, popovers, empty states, panels of a few rows (the "Due"
  tasks), page headers with their menus and fields (the collection page's, the table's, the task list's).

Deleted on 2026-11-04: the SwiftUI gallery (`CollectionCardsView`'s `LazyVGrid`, `GalleryCard`), the SwiftUI table
rows (`TableRow`), the full-size SwiftUI task row, and the SwiftUI wrapper of the folder page (`FolderGridView`,
`CardGrid`). On 2026-11-05: the SwiftUI board (`CollectionBoardView`, `BoardLayout`, `BoardDragModel`,
`HeldCardLayer`, `FrameDriver`); the SwiftUI mindmap (`MindmapView`, `MindmapTopicBody`, `MindmapPicture`,
`MindmapKeyCatcher`); the SwiftUI whiteboard (`BoardView`, `BoardCardView`, `BoardCardBody`, `BoardFarCards`,
`BoardEdges`, `BoardKeyCatcher`, `BoardTableView`, `BoardInkView`, `BoardRichLink`, `BoardExportPage`, `BoardToolbar`).

## The plugin SDK: `makeNSView` (SDK 2.5)

Added API, nothing removed (the SDK only grows, docs/PLUGIN-LOADING.md):

- `ViewType.makeNSView` and `CollectionViewType.makeNSView`, optional. The shell puts a page's AppKit view in the
  page as it is (no hosting view); the collection page shows a collection view's. A type that gives one makes its
  `makeView` the same view (`NativeView { ... }`), so there is still one implementation. All Notes, the gallery and
  the board use it.
- `NativeHostedView`: what the host tells the view (`NativeViewEnvironment`: the theme, the toolbar's room) and the
  size it wants when embedded (`fittingSize`). `NativeView` shows such a view in SwiftUI with the environment's values.
- `Follow`: an observation loop for AppKit views, which runs only on a new value (what the shell's views use).
- SDK 2.6: `CollectionViewModel.reloadSoon`, `isAffected(by:)` and `settled()`, `package` (the app's own plugins
  only), counted by the ABI check as added.
- SDK 2.8: what an AppKit canvas needs from `InfiniteCanvas`: `CanvasCamera.move(to:scale:animated:)` (animated moves
  stepped on the display's frames, so AppKit and SwiftUI views follow them alike), `destination`, `isFlying`,
  `scroll(with:at:wheelZooms:)`, `scrollZooms`, `magnify(with:at:)`, `Motion.Spring.progress(at:)`,
  `CanvasDotGridLayer` and `CanvasZoomControlsView`. `CanvasDotGrid` and `CanvasZoomControls` are these in SwiftUI.
- Third-party plugins keep their SwiftUI `makeView`; `makeNSView` is there for a view of many items.

## Steps, biggest measured cost first

Each step: build it in its own worktree, measure before and after with `scripts/perf-ui.py` and a copy of a real
vault, compare the screen with Craft (`ui-verify`), merge. A step is done when its numbers meet the goal.

1. **Native cards** (~2 days). One AppKit `NoteCardCell` (title, preview lines, cover, footer, hover lift and ring
   as layers) used by All Notes (`CardGrid` keeps its placement, swaps `CardHost` for the cell) and by the gallery
   (`CollectionCardsView` becomes a `CardGrid` too). `NotePreview` is drawn by Core Text. Target: open < 100 ms.
2. **Page chrome** (done, "The shell"). The page header (title, breadcrumbs, toolbar buttons) and the tab's view host in
   AppKit, so opening a note builds only the editor. Target: note switch < 45 ms (the `perf-ui` budget).
3. **Lists** (~2 days). Tasks, search results, backlinks, Quick Open and the palette as `NSTableView` with reused
   row views. Target: open < 50 ms with 2,000 rows.
4. **Sidebar** (~1.5 days). The leading column (sections, folder tree, tags) as an `NSOutlineView` with Loam's rows;
   its slide is already AppKit (`SlidingColumn`). Target: sidebar toggle < 50 ms, tree of 5,000 notes scrolls at 120 fps.
5. **Collection table and kanban** (~2 days). Same cells and reuse as step 1 and 3.
6. **Shell root** (done, "The shell"). `ShellWindow` (status bar, overlays) in AppKit, so nothing re-evaluates a whole-window
   SwiftUI body on a state change.

## Costs and risks

- About 10 working days for steps 1-6, measured step by step; steps 1 and 2 give most of what is felt.
- One implementation of the moved views, AppKit: an iPhone shell, when it is built, draws its own.
- Accessibility: AppKit cells need their labels and button traits set by hand (`tappableRow` did it in SwiftUI).
- Hover lift, tilt and cascade animations are redone with Core Animation and `Motion`, Reduce Motion honoured.
