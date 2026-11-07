# Loam for agents

How an outside coding agent (Claude Code, Codex, OpenCode, Pi, Antigravity) works in a vault and builds plugins for
Loam, from the user's terminal. Modelled on Aside's developer setup: a command line, a guide it prints, and a short
skill in each agent that says to read the guide.

## The goal

VISION.md's test: someone tells their agent "I want a reading tracker" and ten minutes later has it, in their own
app, in their own notes. So any agent, on its first try, must be able to:

1. use Loam: read, write and organize notes, run any command of any plugin;
2. build a plugin that compiles, works and is tested;
3. see it in the open app, and check it there itself;
4. share it.

Building plugins happens outside the app, in the agent the user already has, because that is where agents are good:
a terminal, a compiler, tests, many steps. The Assistant panel runs those same agents, so it gets the same skill.

## The pieces

| Piece | What it does |
| --- | --- |
| `loam` | the app's command line (`Loam.app/Contents/Helpers/loam`): every command (`loam list`), the plugin tools (`loam plugin new | build | test | install | enable | remove`). Settings > Developers links it into `~/.local/bin`. |
| `loam guide [topic]` | the knowledge, shipped with the app so it always matches its version: the rules, notes, commands, plugins step by step, UI plugins, tests, driving the app, sharing (`LoamCLI/Guide.swift`). |
| The "loam" skill | a short `SKILL.md` that says when to use Loam and to run `loam guide` first (`LoamCLI/AgentSkill.swift`). `loam skill install`, or Settings > Developers, writes it into `~/.claude/skills` (Claude Code, OpenCode), `~/.codex/skills` (Codex) and `~/.agents/skills` (Antigravity, Pi, OpenCode, Codex). Its `version` says when a copy is old. |
| `loam app` | the open window, for the agent to see its work: `info`, `list`, `open <note>`, `run <command>` (UI commands too), `shot <png>`, `relaunch` (loads rebuilt plugins: code is never reloaded in place). A Unix socket per open vault, `/tmp/loam-<uid>/<hash>.sock`, 0600, served by the app in every build (`LoamCLI/AppChannel.swift`, `NotebookApp/Shell/AppChannelBridge.swift`); unlike the debug channel of test instances, it cannot type or click. |
| `loam plugin test <id>` | the plugin's `swift test` against the app's SDK, as JSON {id, ok, log}. |

## The workflow the guide teaches

1. `loam plugin new <id> [--ui]`: a working package in `.loam/plugins/<id>/`.
2. Write it, reading the SDK's sources for the exact API (the guide prints where they are).
3. `loam plugin build <id>` until `ok`; `loam plugin test <id>`, with tests for what it added.
4. Show the user its permissions, then `loam plugin enable <id>`.
5. Run its commands with `loam`; for a UI, `loam app relaunch`, then `loam app shot` and look.
6. Share: a git repository, installed with `loam plugin install <url>`.

## Not yet

- An MCP server (`loam mcp`) for agents without a terminal (Claude Desktop, ChatGPT).
- Reloading a rebuilt plugin without relaunching the app.
