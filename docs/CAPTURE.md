# Quick capture

Save what you copied, from any app, in one keystroke. The design and its reasons: [design/CAPTURE-PLUGIN-PLAN.md](design/CAPTURE-PLUGIN-PLAN.md).

## What the user does

1. Copy something: a link, a picture, a PDF, some text, files in Finder.
2. Press **⌃⌥Space** anywhere (the `capture.open` command's shortcut; Settings > Shortcuts changes it). A small window
   opens already holding it.
3. Press **Enter**, or type a few words first. Escape closes without saving. ⌘V adds another item.

One line then says what happened and where (top of the screen), with **Open** and **Undo**. The menu-bar icon (Loam
keeps running when its window is closed: Settings > Appearance > In the Background) and the status-bar button open the
same window.

## What happens

1. **At once, without any agent** (`capture`, Foundation only): one note per item in the capture collection
   (`Saved for later/` by default, created with a Gallery and a Table `.base` at the first capture). Files go through
   the `attachments` service. Exact duplicates (same canonical URL, same bytes, same text) are not saved again: the
   window says "Already in your notebook" and a typed note is added to the existing item.
2. **A second later**: a link gets its page's title (the note is renamed), description and preview picture (`cover`);
   a PDF its first page as `cover` and its text for the agent.
3. **One agent turn** (`capture-ui`): `assistant.ask` in Auto mode with one fixed prompt (`CapturePrompt`), on the
   Assistant's agent. The agent titles, summarizes (`**TLDR** — …`), tags, links related notes and merges a duplicate,
   using its own tools and the `loam` CLI, then ends with one JSON line Loam reads for the line. Changes outside the
   capture are reported ("also changed 2 other notes"); Undo runs `assistant.undo-turn`, then sends the notes and files
   to `.trash/`. A vault file `.loam/ai/capture.md` replaces the prompt's instructions.

Page, PDF and clipboard text are fenced as `<untrusted-content>` in the prompt; the agent still runs with shell access
in Auto mode (the trade-off is in the plan). Concealed or transient pasteboard types (password managers) are never read.

## The note

```markdown
---
type: link
source: https://inkandswitch.com/essay/local-first
captured: 2026-11-04T10:12:31+01:00
cover: Attachments/cover.webp
tags: [local-first, essay]
---
# Local-first software

**TLDR** — …

> The page's description

[Open the original](https://www.inkandswitch.com/essay/local-first/)
```

Files and text also get `content-hash` (SHA-256 of the original bytes, or of the text lower-cased with its whitespace
collapsed). A typed note goes under `## Note`.

## Which agent

The Assistant's `agent` setting is `auto` by default: the agent signed in with a subscription (Claude Pro or Max,
ChatGPT Plus or Pro…), then a free account, then an API key, then any ready agent; Claude Code, Codex, Antigravity, Pi,
OpenCode among equals (`AgentCatalog.preferred`). Codex's plan and its usage windows come from its own app server
(`account/read`, `account/rateLimits/read`, as CodexBar reads them) and show in Settings > Assistant. Capture's own
`agent` setting is `auto` (the Assistant's choice) or a named agent.

## Settings

`plugins.capture.settings`: `collection` (the folder), `agent` (`auto`), `useAgent` (off: saved, not sorted).

## Commands

| Command | Does |
| --- | --- |
| `capture.add` | `url`, `text` or `file`, optional `note`: saves one item (CLI and agents) |
| `capture.recent`, `capture.undo` | this session's captures; the last one (or `path`) to the trash |
| `capture.set-collection` | `path`: where captures go |
| `capture.open` | the window (palette, shortcut) |
| `capture.show-recent`, `capture.choose-collection` | palette popups |
| `assistant.default-agent` | the agent `auto` resolves to, with its plan and usage |

## Not built yet

Share extension, browser extension or `loam://capture` URL scheme, drag and drop onto the window, rich text to Markdown,
Claude Code's usage windows (they need its OAuth token from the Keychain), scheduled consolidation.
