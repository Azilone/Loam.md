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
- UI timings (note open, typing) are not covered here: profile them with `sample` on a release agent instance (`scripts/agent-run.sh --release`).

## Frame rate

`make perf-ui` (`scripts/perf-ui.py`) runs the actions a person feels on a release agent instance, five times each
after a cold run (the two scroll rows, twice), and fails when a median goes over its budget: the longest frame after a note switch (45 ms), All
Notes (150 ms), each sidebar (50 ms), a new tab and closing it (75 ms), Quick Open (60 ms), and the frame rate while scrolling All
Notes (100 fps) and a note (110 fps). Run it before saying a change that touches the shell, the editor or a page is
done. It prints the load average: on a busy machine (another build) every frame comes late; rerun when it is idle.
`PERF_UI_ARGS="--template DIR"` runs it on a copy of another vault.

- `LOAM_FRAMES=1 scripts/agent-run.sh NAME --release`: the instance logs, each second with a late frame, the frames
  its main thread drew (`frames: … late, longest … ms` in its `app.log`). It does not see the render server. Each
  click or key sent with `loam-ctl` adds `input click: first frame +… ms, then … late of …, longest … ms`: the
  longest frame in the half second after it is the latency to compare (a note switch, a sidebar's slide).
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
