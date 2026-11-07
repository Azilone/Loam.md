---
name: ui-verify
description: Verify a Loam UI or UX change in the real app without the screen. Use after changing a view, layout, shortcut, animation, theme or editor behaviour, before saying it is done, or to compare a screen with Craft.
---

Drive your own instance of the app through its debug socket. It is background, hidden-window and locked-screen
safe, and shared by nobody: other agents run their own. Never use `computer-use` for Loam, and never `pkill`.

Pick the cheapest check that can fail for your change:

- **Logic, state, commands**: a unit test (`swift test --filter`, `UIPluginHarness`).
- **A view's look alone** (a card, a row, a panel): an offscreen snapshot test, `NSHostingView` plus `cacheDisplay`
  (`SettingsTests.snapshot`, `CanvasUITests.testSnapshotsOfTheDemoBoard`).
- **Anything that needs the real window**: shell, focus, typing in the editor, hover, drag, popovers, animation,
  light/dark. Steps below.

## Steps

1. Start an instance named for your task. It builds in the foreground (debug configuration, a few minutes the first
   time: Bash timeout 600000, run the same command again on a timeout) and prints `socket=…`:
   `scripts/agent-run.sh NAME` (`--vault DIR` for your own vault, `--no-build` to reuse the last build).
2. Set the scene: `scripts/loam-ctl -i NAME open Welcome.md`, then `type`, `key`, `click label:Tasks`, `hover`,
   `theme dark`, `window 900 600`. Write a scenario with several steps to a file and run `loam-ctl -i NAME script FILE`.
3. Look: `loam-ctl -i NAME shot /tmp/NAME-a.png`, then Read the PNG. Check state in text too, since a picture can
   hide it: `editor` (text, selection), `ax --find TEXT` (elements and frames), `hit X,Y`, `info`.
4. Animation: `loam-ctl -i NAME film /tmp/NAME-open --count 8 --interval 40 --then "key cmd+t"`, then Read the
   frames. Compare with `reduce-motion on`. Targets are in points (screenshot pixels / 2).
5. Craft comparison (UI changes, see AGENTS.md): capture the same screen of Craft (built-in browser on
   https://docs.craft.do, or your Chrome) and read both PNGs. The change is done when they match.
6. Stop: `loam-ctl -i NAME quit`.

A step has passed when the PNG or the printed state shows the expected result, not when the command exits 0.

## When it misbehaves

- A `view` shot taken right after navigation can catch a transition half drawn: `wait 500`, or shoot with `--layers`.
- An unknown label or id: `loam-ctl -i NAME ax --find PART` lists what exists. SwiftUI elements appear only by label
  or identifier they set (`.accessibilityLabel`); fall back to `X,Y` from a screenshot.
- The instance does not answer: `tail -30 /tmp/loam-instances/NAME/app.log`, then start it again (the same name
  restarts it).
- Full command list, limits and the socket protocol: [docs/AGENT-TESTING.md](../../../docs/AGENT-TESTING.md).
