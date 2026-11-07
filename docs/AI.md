# AI

How Loam's assistant works: the choices it rests on, and what is not built yet. It lives in `Assistant` (logic) and
`AssistantUI` (the bubble and panel), and follows VISION.md's "AI native": the agent is a user like any other, any
provider, the user decides.

The assistant is a floating bubble that opens a chat panel. It drives the coding agent the user already has (Claude
Code, Codex, Antigravity, OpenCode, Pi) on the whole vault, with saved prompts. Every agent edits notes through the
panel, and the turn's Undo puts them back. In Ask mode, Claude Code's edits wait for Allow (Ask and Read only load only
the vault's Claude settings, so a user's `bypassPermissions` cannot skip the questions). OpenCode's free models need no
key. Text selected in a note follows into the composer as a "Selected Text" chip, with Explain, Analyze,
Summarize and Translate. Gemini CLI is not supported: Google moved its subscribers to Antigravity.

## What the others do (October 2026)

- **Notion AI.** Space on an empty line opens a prompt that writes in place; "Edit with AI" on a selection (rewrite,
  tone, translate, grammar, custom instruction); an AI block whose saved prompt runs again on each view. The Agent: a
  floating button bottom right that becomes a sidebar, creates and edits pages and databases, reads files and
  connected apps (Slack, Drive, Gmail, calendar). Saved requests ("skills"), a "My Notion AI" page of personal
  instructions, a model picker (Claude, GPT, Gemini, Grok). Custom Agents run on a schedule or an event, with a log
  of every run that can be undone. Meeting notes, research mode, database autofill.
- **Craft.** An Assistant panel with two modes: Explore proposes changes and waits for approval, Execute applies them
  live. It adds, replaces and restyles blocks, reorganises a document, creates pages and folders, builds summary
  pages from a tag. Providers: Craft's own, ChatGPT sign-in or an OpenAI key, a Claude API key, and Apple's on-device
  models, free and offline. Custom prompts and personal preferences. An MCP server so Claude or ChatGPT work in Craft
  from outside.
- **Tolaria** (closest to Loam: Markdown and YAML files, local, git). Two tiers: the user's coding agents (Claude
  Code, Codex, OpenCode, Pi, Gemini CLI) edit the vault with their tools; API or local models only chat, without
  write tools.

What everyone has: actions on a selection, a chat panel that knows the open page, edits that can be reviewed or
undone, saved prompts, personal instructions, a choice of models. What only some have: agents on a schedule (Notion),
a vault built for outside agents (Craft's MCP, Tolaria's files).

## Choices

1. **The user's own agent, never a token.** Loam starts the agent CLI the user installed and signed in to, with the
   vault as its working folder, and talks to it over its own JSON stream. The subscription stays in the vendor's
   client. Anthropic's terms forbid an app to "route requests through Free, Pro, or Max plan credentials", but not
   "an end user [signing] in to the unmodified Claude Code binary": so Loam runs the official `claude`, never the
   Agent SDK with a subscription (what Craft Agents OSS does) and never an ACP adapter built on that SDK. Codex's
   ChatGPT sign-in works the same way, through the `codex` binary.
2. **One integration per protocol, not per vendor**, as Tolaria does, but kept alive across turns:

   | Agent | Command | Protocol | Approvals |
   | --- | --- | --- | --- |
   | Claude Code | `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages` | stream-json, one process per chat, `--resume <id>` after a relaunch | Ask mode: over stdio (`--permission-prompt-tool stdio`) |
   | Codex | `codex app-server` | JSON-RPC: `thread/start`, `turn/start`, `turn/interrupt`, `thread/resume` | `item/*/requestApproval` |
   | OpenCode | `opencode acp` | ACP: `session/new`, `session/prompt`, `session/cancel` | `session/request_permission` |
   | Antigravity (`agy`) | `agy --input-format stream-json --output-format stream-json --print=` | stream-json, prompts on stdin | none: Auto approves all, Ask only accepts edits |
   | Pi | `pi --mode rpc` | JSONL commands: `prompt`, `abort` | none |

   Google moved subscribers from Gemini CLI to Antigravity (`agy`) in June 2026: `gemini --acp` serves API keys, `agy`
   comes after. OpenRouter, Grok and other keys come through OpenCode or Pi, which handle them; a built-in loop on the
   Meetings client waits until someone needs it without installing either.
3. **No MCP in v1.** The agent works on the files (its working folder is the vault, notes are plain Markdown) and runs
   Loam's commands with the `loam` CLI, whose full path the instructions give. The app sees every change through its
   file watcher. `loam mcp` comes when we need what files cannot do: acting on the open app (open a note, read the
   selection).
4. **Three modes**, in Craft's mode menu: *Auto* edits without asking. Claude (`--permission-mode acceptEdits`) also runs Bash with no limit, so any
   shell command runs, not only `loam`; its other tools without a prompt are Read, Edit, Write, MultiEdit, Glob, Grep,
   WebFetch, WebSearch and TodoWrite. Codex (`workspace-write`) asks for no approval; Antigravity
   (`--dangerously-skip-permissions`) approves everything. *Ask* proposes and waits (Claude over stdio, Codex and ACP
   approvals; Antigravity cannot ask while printing, so its Ask only accepts edits). *Read only* answers and never
   edits (Claude `--permission-mode plan`, Codex `read-only`). Whatever the mode, each
   turn starts with a checkpoint, and the turn's summary ("3 notes changed") has an Undo that puts the files back.
   Outside writes clear the editor's undo, so this checkpoint is the only way back.
5. **Prompts and instructions are Markdown in the vault.** Saved prompts in `.loam/ai/prompts/<slug>.md` (`title:` in
   frontmatter, the prompt as body, as Craft's "Create Custom Prompt": an optional title and a prompt); the user's
   instructions in `.loam/ai/instructions.md`, added to every chat. Chats themselves are per device, in
   `.loam/cache/ai/chats/`.
6. **One plugin pair, `Assistant` and `AssistantUI`.** Removing them leaves no trace; the agent needs nothing else.

## Craft's Assistant, measured (docs.craft.do, October 2026)

The panel copies it one to one; these numbers come from the live page.

- **Motion** (read from the page's React props): one container whose width and height spring from the bubble to the
  panel, Framer's `spring(duration 0.5, bounce 0.2)`, anchored at the bottom right; the content cross-fades, out in
  0.1 s, in over 0.2 s after 0.05 s. Light theme: the glass `rgb(252, 253, 254)`, ink `rgb(31, 34, 37)`, send
  `rgb(46, 109, 233)`. `AssistantUI/CraftStyle.swift` holds all of it.
- **Bubble**: a 112×40 capsule 16 pt from the window's right and bottom edges, radius 18, a blurred glass
  (`blur 32`, saturation 1.5) with a layered shadow; inside, a 32-pt button (radius 14, padding 4/13/4/7) with the
  Assistant icon and "Assistant".
- **Panel**: replaces the bubble at the same corner, 464×704 (shorter in a short window), radius 18, the same glass
  over `#1C1C1E`, growing from the bubble.
  - Header, 16 pt from the edges: a 28-pt list button (radius 8) opening *Conversation History* (past chats, then
    "Usage and Limits"); the chat's title in a 30-pt capsule (white 6 %, 1-pt white 6 % border, 13 pt semibold, "New
    Chat" at first); a 32-pt close button (radius 10).
  - Empty chat: "Suggestions" (13 pt semibold), five 28-pt rows (radius 10, a 20-pt icon, 13 pt medium) and "Show N
    More". Craft's: Research a Topic, Semantic Search, Get an Overview, Summarize Documents, Organize by Topic.
  - Composer, a card 12 pt from the edges (radius 12): the context as a chip (a 30×36 icon tile, the page's name in
    13 pt semibold over its kind in 12 pt, a 20-pt × to remove it); "Message Craft Assistant" (14 pt medium); a row
    of 32-pt controls: "+" (*Add Additional Context*: a search field, "Focus on…" All Docs, Tasks, Calendar, then
    Folders), the model ("Fast", menu: Max, Fast checked), the mode ("Auto", menu of icon, title and subtitle rows: Auto,
    Smart Search, Document Review, Web Research, Help Center), and the send button at the right (brand blue circle).
  - Menus: rows 32 pt, radius 10, 13 pt medium, a check on the current one.
- **Settings > Assistant**: "AI Usage and Limits"; *Saved Prompts* ("Save up to 20 prompts…", "+ Add Prompt" opening
  *Create Custom Prompt*: Title, optional, and the prompt); a switch per Space.
- Loam's mapping: the model pill picks the agent and its model ("Claude · Sonnet", "Codex · GPT-5"); the mode pill
  holds Auto, Ask and Read only with Craft's row layout; suggestions are the saved prompts, then built-in ones; the
  context chip is the open note, "+" adds notes and folders; "Usage and Limits" shows the agent's sign-in and plan.

The `agent` setting is `auto` by default: the agent signed in with a subscription first, then a free account, an API
key, any ready one (`AgentCatalog.preferred`). Codex's plan and usage windows come from `codex app-server`
(`account/read`, `account/rateLimits/read`, CodexBar's method) and show in Settings > Assistant. Quick capture uses the
same agent ([CAPTURE.md](CAPTURE.md)).

## Not built yet

- `loam mcp`: every command as an MCP tool, Claude's approvals through `--permission-prompt-tool`, and actions on the
  open app (open a note, the selection), which needs a channel into the running app (today only the debug socket).
- An AI button on the format bar, the prompt on Space.
- Ask the vault by meaning (Truffle), with `[[links]]` to the sources.
- Building a plugin by asking (the `plugin-dev` skill and `loam plugin new|build`), VISION.md's flagship.
- Claude Code's usage windows (its OAuth token lives in the Keychain item `Claude Code-credentials`; reading it would
  break "Loam never sees the agent's credentials").
- Scheduled agents (a morning recap in the daily note), an AI column in collections, memory, Meetings on the same
  keys.

Left out: Notion's AI block (a prompt that changes the note each time it is viewed goes against "your notes change
only when asked"), connectors to Slack or Gmail (MCP servers the user adds to their agent cover them).
