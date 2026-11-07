# AGENTS.md

Loam is a local-first Markdown notebook for the Mac where everything beyond writing is a plugin. Read
[docs/VISION.md](docs/VISION.md) before any product decision.

## Rules

- New behaviour goes in a plugin; the core (`LoamCore`) stays minimal.
- Plugins talk through contracts (`PluginKit` / `PluginKitUI` services) registered on their `PluginContext`.
- `PluginKit`, `LoamCore` and plugin logic use Foundation only (they build on Linux); UI lives in `App/`.
- Notes are plain Markdown (CommonMark + GFM, YAML frontmatter).
- Work on `~/TestVault` or a copy; a real vault changes only when the user asks.
- English for code, comments and docs.
- A commit message has no `Co-Authored-By` line (the `commit-msg` hook drops it).

## Build, test, run

```bash
make test-fast              # the tests your changes reach (~1 min), while iterating
make test                   # everything (~5 min), before saying a change is done
scripts/agent-run.sh NAME   # build + start your own Loam [NAME] on a vault copy, prints its socket
make ps                     # every Loam and build running, with its worktree and branch
```

Name your instance after your worktree or task (`agent-run.sh theme-gallery`), so the user can tell the windows
apart. Quit it when you are done: `scripts/loam-ctl -i NAME quit`. Its default debug build is the fast one;
`--release` only to measure performance. `make run` and `make dev` are the user's.

The machine is shared with other agents: builds and tests take turns on a machine-wide lock (`scripts/build-lock.sh`), so
run Swift through these targets and scripts, and a `build-lock: … waiting` line means another build is ahead of yours.
App builds (`agent-run.sh`, `dev-refresh.sh`, `build-app.sh`) have their own lane and never wait behind a test run.
Iterate with `make test-fast`; run `make test` once, at the end, in the background. Work in your own worktree, so a
build there compiles only what you changed.

Keep the loop short: make all your edits, then build once (`dev-refresh.sh`, which `agent-run.sh` and `make dev` call, swaps
only the rebuilt Swift code into the bundle: ~25 s). Merging branches and removing worktrees is git only: no build, no
tests, unless the merge had conflicts.

## Releasing an update

- **Changelog, with every change people can see**: one line under `## Unreleased` in [CHANGELOG.md](CHANGELOG.md), in
  the same commit, written for the people who use Loam: what they can now do, in plain words, as a release note reads
  ("Reorder a board's columns: drag a column by its header."; a fix starts with "Fixed:"). Work only developers see
  (refactors, tests, docs, scripts, agent rules) leaves it as it is. That section is the release's notes, as it is:
  a release whose section is empty publishes nothing.
- **Beta first.** Release, deploy, publish or ship means beta: `git push origin origin/main:refs/heads/beta`. Prod
  (everyone) only when the user says prod, and only for a commit already out in beta: first rename `## Unreleased` to
  `## <version> - <date>` (the beta's version without `-beta.N`) with a new empty `## Unreleased` above it, commit and
  push `main`, then `git push origin origin/main:refs/heads/prod`. The `beta` and `prod` branches move only this way.
- The pre-push hook publishes in the background, ~5 min: `~/Library/Logs/Loam/release.log` ends with
  `Published <version>` ([docs/UPDATES.md](docs/UPDATES.md)). If the branch is already at that commit, the push does
  nothing: run `scripts/auto-release.sh origin <beta|prod> <commit>` instead. It works only on the user's Mac (the
  signing key and `core.hooksPath scripts/git-hooks` live there).

## UI: Craft is the source of truth

- Every layout, spacing, colour or behaviour question is answered by the real Craft: https://docs.craft.do in a
  browser, or the Craft app through computer use. If it asks to sign in, ask the user.
- What Loam already took from Craft: [docs/design/CRAFT.md](docs/design/CRAFT.md).
- Movement follows [docs/design/MOTION.md](docs/design/MOTION.md), springs from `Motion` (`PluginKitUI/Motion.swift`),
  Reduce Motion honoured.
- A UI change is done when your instance's screenshot matches the same screen in Craft: the `ui-verify` skill.

## Go deeper

- A plugin, command, panel or service: the `plugin-dev` skill.
- A contract, a module dependency, shell UI or the repository layout: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- Driving an instance (`loam-ctl` commands): [docs/AGENT-TESTING.md](docs/AGENT-TESTING.md).
