# Performance tests

`make perf` generates `~/LoamPerfVault` once (`scripts/make-perf-vault.py`: 20,000 notes, ten years of daily notes,
wikilinks, tags, frontmatter, tasks, a few 1 MB notes, 2 GB of sparse attachments), builds `LoamBench` in release and
times the work that grows with the vault: the walk, the note graph, search, tasks. Each line gives the first run and
the median of the next ones; the command fails when a median is over its budget.

- Budgets (`Tests/LoamBench/main.swift`): 16 ms for what runs per save or keystroke on the main thread, ~100 ms for a
  popup's answer, 3 s for launch work in the background, and 5, 20, 50, 250 and 300 ms for the other measures. Change
  one only with a reason in the commit.
- Another vault: `make perf PERF_VAULT=~/Copy` (never a real vault: copy it first). Options:
  `PERF_ARGS="--runs 10 --no-budget"`.
- UI timings (note open, typing) are not covered here: `make perf-ui` below, and `sample` on a release agent instance (`scripts/agent-run.sh --release`).

## Frame rate

`make perf-ui` (`scripts/perf-ui.py`) is the guard against frame-rate regressions: it runs each scenario below on a
release agent instance, five times after a cold run (scrolls twice), and fails (exit 1) when a median goes over a
budget. Each measured input is judged on its longest frame (the first frame's latency included) and on the late
frames in the half second after it, summed over the inputs of a run; a scroll on its lowest frame rate. Run it on the
copy of the real vault before saying a change that touches the shell, the editor or a page is done:
`make perf-ui PERF_UI_ARGS="--template ~/LoamTest-RealVault"` (~6 min; never the iCloud vault itself). The load
average is taken before and after: above the number of cores (other builds), a pass still counts but a scenario over
budget is not judged (exit 2), since frames then come late for reasons outside the app; rerun when the machine is
idle, or `--judge-busy`. `--budget-scale 0.2` checks that the guard fails. `--scenario sidebar,tab`
runs only the scenarios whose name contains a word, `--json FILE` writes the results, `--no-budget` only reports.

| Scenario | What runs | Budget (median) |
| --- | --- | --- |
| note → note | `open` one note, then another | 45 ms, 4 late |
| All Notes | a note, then `open notes:` | 60 ms, 6 late |
| card → note, back to All Notes | click the first card on All Notes; then Cmd+[ | 70 ms, 5 late; 50 ms, 5 late |
| All Notes ↔ Tasks | click the sidebar rows in turn (pages kept) | 70 ms, 5 late |
| Tasks from a note | a note, then click the Tasks row | 80 ms, 7 late |
| left sidebar, note / All Notes; right sidebar | `run sidebar.toggle-leading` / `-trailing` | 50 ms, 4 late |
| new tab, Escape; close tab | Cmd+T then Escape; Cmd+W on that tab | 75 ms, 6 late; 220 ms, 4 late |
| quick open; quick open typing | Cmd+O; then "projet", a key each 0.55 s | 60 ms, 6 late; 40 ms, 3 late |
| typing a long note | the vault's longest note, at its end: Return and 12 keys as fast as `loam-ctl` sends them | 45 ms, 12 late |
| gallery open; Galerie → Table | `open` the gallery base from a note; click its Table tab | 80 ms, 6 late; 90 ms, 5 late |
| scroll All Notes / a note / the gallery | 12 (10) points per frame down then up, 1.5 s each | 100 / 110 / 100 fps |

Close tab has one ~150 ms frame today: its budget holds it there until that hitch is fixed.

Budgets are today's medians on `~/LoamTest-RealVault` with headroom, in `BUDGETS` of the script; change one only
with a reason in the commit. The gallery scenarios need `BASES/GALERIE DES RESSOURCES.base` and are skipped on
another vault. Clicks are at fixed points of the 1300 x 850 window the script sets: All Notes (82,141), Tasks
(82,175), the first card (400,250).

- `LOAM_FRAMES=1 scripts/agent-run.sh NAME --release`: the instance logs, each second with a late frame, the frames
  its main thread drew (`frames: … late, longest … ms` in its `app.log`). It does not see the render server. Each
  click or key sent with `loam-ctl` adds `input click: first frame +… ms, then … late of …, longest … ms`: the
  longest frame in the half second after it is the latency to compare (a note switch, a sidebar's slide). It also
  adds `busy click: longest … ms, … ms in … turns`, the main thread's longest run-loop turn and total time in the
  second after: it needs no display, so it measures with the screen locked (where SwiftUI defers its drawing).
- Render and GPU time per frame: `xcrun xctrace record --template 'Animation Hitches' --attach PID --time-limit 8s`,
  then export the `hitches-renders` and `hitches-gpu` tables. The trace covers the whole display, not only Loam,
  and an agent instance runs inactive with its accessibility tree on: confirm a finding in the real app.
- Click by coordinates while measuring: `id:`/`label:` targets walk the accessibility tree and stall the main thread.
- A scroll to measure: `loam-ctl scroll X,Y 8 --for 1500` scrolls 8 points per frame for 1.5 s, as a trackpad.
- `xctrace` leaves a 6-33 GB `instruments*.ktrace` in `$TMPDIR` per recording and can hang past `--time-limit`
  (it did on every sidebar toggle): check `df -h /` first, kill it after 60 s, delete the `.trace` and those
  ktrace files after each run. A loop of recordings without that filled a 460 GB disk.
- A mask over a scroll view's content (`.mask` on a `ScrollView`) makes the render server draw everything under it
  off screen each frame it moves: on "All Notes" it put a third of the frames over budget. Fade over a known
  backdrop colour instead (`scrollEdgeBackdrop`).

## Typing

Each key sent with `loam-ctl` gets its `input key` line even when the next one comes within half a second: the meter
writes the one it follows when a new input arrives. Bursts at 15 keys a second, release build, a copy of the real
vault plus a 22 KB note with tables, tasks, code, embeds and links and a generated 1 MB one, on a machine under load
(load average 15-35): the median of each key's first frame (two frames at most is 16 ms on a 120 Hz display).

| Note, caret | Before | After |
| --- | --- | --- |
| short note | 9.7 ms | 5-6 ms |
| 22 KB, tables and the rest | 12-15 ms | 6-12 ms |
| longest of the real vault (174 KB), top / end | 44 / 32 ms | 19 / 18 ms |
| 1 MB, top / end | 147 / 340 ms | 90 / 46 ms |
| Return in a list, 174 KB / 1 MB | 31 / 130-470 ms | 21 / 67 ms |
| Backspace joining two blocks, 174 KB / 1 MB | 50 / 54-1100 ms | 10 / 43 ms |
| Undo; paste of 150 lines (1 MB) | 4-7 ms; 52 ms | 4-7 ms; 30 ms |

What a keystroke no longer does (`App/Sources/MarkdownEditor`):

- Write the whole note's Markdown in its frame: an untouched block keeps the text it was read with, so `NoteWriter`
  compares it with its lines at once, and a note longer than 50,000 characters is written 30 ms later, out of the
  frame (`BlockSession.deferredLength`; written at once before another note shows, a save, a read by a plugin).
- Read every table again (parse, cell layout, drawing, accessibility): a table whose block did not change is left.
- Walk the page five times for its embeds, tables, diagrams, live blocks and headings (`PageScan`, one pass), ask the
  disk about every embed (its key is kept until the vault changes), search the page for `</details>`.
- Lay out text far from the screen: block views are placed from a screen above what shows to just below it, not from
  the note's start (nor over the whole note when its end shows), and the outline's heading positions are exact down
  to the end of what shows, estimated below. That one laid a 1 MB note out after each pause, up to a second.

Left, outside the editor's text: the outline's ticks (`OutlineTicks`) evaluate their SwiftUI body on each keystroke
of a long note, as the page's scroll metrics change, more main-thread time than the editor's own on the 174 KB note;
after a save, `VaultChanged` has the note graph parse the note on the main thread (a few hundred ms for 1 MB, under load) and the file
explorer, tags and habits read the vault's stamps. TextKit 2 itself shifts every paragraph after the caret on each
edit (`NSTextContentStorage`), which is what remains of the 1 MB note's time.
