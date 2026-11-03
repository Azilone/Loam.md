# Benchmarks

The numbers on the Loam website, how they were measured, and the raw data behind them. Everything here can be run
again: the scripts are in [`scripts/bench`](../../scripts/bench), the raw results in [`raw`](raw).

Agents measured on 2026-10-30 at commit `ef3023c` (the agent harness: compact JSON, recipes, a filtered `loam list`);
memory and launch the same day at commit `25f572d`.

## Results

### An agent answering questions about your notes

Median per task, 6 everyday questions, 3 runs each, the same 83 notes in each setup.

| Setup | Tokens | Time | Right answers |
| --- | --- | --- | --- |
| Loam CLI + skill | 119,000 | 12.6 s | 18/18 |
| Obsidian (plain files) | 138,600 | 13.9 s | 18/18 |
| Notion MCP | 237,800 | 15.9 s | 18/18 |

- Notion's MCP costs twice the tokens of Loam for the same answers, and about 25 % more waiting.
- Loam came out ahead of plain files in this run, 119,000 tokens against 138,600 and 1.3 s sooner, but plain files
  moved by as much between two runs with no change on their side: on 83 notes the two are even within the noise.
- On the 2,483-note vault (Loam and plain files only, Notion was not copied) Loam is no longer behind: 137,200 tokens
  and 12.3 s, against 155,700 and 15.1 s for plain files. Before the harness work it spent 158,700 there against
  130,800, mostly on questions where it listed many notes through the CLI; that output is compact JSON now.
- The tail is still wide: p90 is 251,700 tokens for Loam and 227,000 for plain files on the big vault, when the agent
  lists many notes through the CLI. See [What to improve](#what-to-improve).
- Notion's row is from an earlier run the same day (same model, questions and notes): its benchmark page was gone by
  the later run.
- About 33,000 tokens of each task are Claude Code's own fixed cost: the same setup asked to reply "ready" spends that
  much (task `-1` in the raw data).

### Memory and launch

Median of 10 launches, the same 10,000-note vault.

| App | Memory at rest | First window |
| --- | --- | --- |
| Loam 0.x (Swift) | 235 MB | 1,506 ms |
| Obsidian 1.14.4 (Electron) | 633 MB | 540 ms |
| Notion 7.41.1 (Electron) | 1,493 MB | 591 ms |

- Loam uses a third of Obsidian's memory and a sixth of Notion's.
- Loam shows its window last. Obsidian and Notion show a window before their content has loaded, while Loam shows it
  once its plugins have started, so the comparison favours them. It is still not a claim Loam can make, and the
  website does not make it.
- Before commit `25f572d` Loam took 4.8 s on this vault: reading every note held the launch. That work now runs in the
  background.

## How it was measured

### Agent tokens and time ([`bench-agents.py`](../../scripts/bench/bench-agents.py))

- **Agent:** Claude Code 2.1.312, `claude -p`, model `claude-haiku-5-5`, effort `medium`.
- **Isolation:** `--setting-sources project`. The user's global `CLAUDE.md`, hooks and skills stay out, and each setup
  only has the tools it would naturally have:
  - **Loam:** a copy of the vault with the `loam` skill in `.claude/skills/loam` and the `loam` CLI on the `PATH`.
    Allowed tools: Read, Grep, Glob, LS, Skill, `Bash(loam:*)`.
  - **Obsidian (plain files):** another copy of the same folder. Allowed tools: Read, Grep, Glob, LS. Obsidian has no
    official MCP server, and reading the Markdown files is how an agent works with an Obsidian vault.
  - **Notion:** the same notes copied as pages under one private Notion page, through Notion's official MCP server.
    Allowed tools: the Notion MCP tools.
- **Prompt:** one sentence saying where the notes are ("My notes are in this folder, a Loam vault."), then the question
  as a user would type it. Nothing tells the agent which tool to use.
- **Questions:** the course price, open clients, a pricing decision, the notes linking to a project, ideas about
  agents, what shipped in a given week.
- **Vaults:** the benchmark vault (not in the repository; any small vault works) has 83 notes: projects, clients, decisions, ideas, a month of daily notes and an archive.
  The 2,483-note vault adds the notes of `scripts/make-perf-vault.py --notes 2400`.
- **Tokens:** input tokens, cache reads and cache writes included, plus output tokens, as `claude -p --output-format
  json` reports them. This is what the model processes for the task, counted across every turn.
- **Time:** wall clock of the whole `claude -p` run.
- **Right answer:** the answer names every expected fact (for example `497` for the price). Every answer was right.
- **Order:** each run asks every question in every setup in turn, so a slow minute of the API hits all setups alike.
- **Cost:** 105 runs, $0.50.

### Memory and launch ([`bench-apps.py`](../../scripts/bench/bench-apps.py), [`winwait.swift`](../../scripts/bench/winwait.swift))

- **Machine:** Apple M1 Pro, 16 GB RAM, macOS 27.0.1.
- **Vault:** `scripts/make-perf-vault.py --notes 10000 --attachments-gb 0`: 10,000 notes, 19 MB of text. Obsidian opens
  it as its vault; Notion cannot open a folder and loads its own workspace.
- **Loam:** a release build (`scripts/agent-run.sh bench --release`).
- **First window:** each app is quit, then started from its executable; `winwait` polls the window list every 5 ms
  until the app shows a window larger than 400 × 300 points.
- **Memory at rest:** 20 s after launch, the resident memory of the app and every process it started (Electron's
  helpers included), from `ps`.
- **Runs:** 11 per app, the first one dropped as a warm-up, median of the other 10. A run where no window appears
  within 20 s is recorded as -1 ms and kept, so it enters the median. Known gap: `bench-apps.py` does not exclude it.

## What to improve

Found by auditing the harness and what the agent reads:

- **Wikilinks:** Loam's note graph reads `[text](note.md)` links, not `[[wikilinks]]`, so `notes.backlinks` misses
  Obsidian-style links and the agent falls back to grep.
- **Big outputs:** piped output is compact JSON now, but `notes.list` still lists every note and `files.tree` the
  whole vault. A default limit and a folder filter would keep a careless call from flooding the context (the p90).
- **Launch:** show the window before every plugin has started.
- **Sample:** 3 runs per question is enough to see a 2× gap, not a 10 % one.

## Run it again

```bash
python3 scripts/make-perf-vault.py --notes 10000 --attachments-gb 0 /path/to/PerfVault10k
scripts/agent-run.sh bench --release --vault /path/to/PerfVault10k
/tmp/loam-instances/bench/Loam.app/Contents/Helpers/loam skill install claude
swiftc -O scripts/bench/winwait.swift -o /tmp/winwait
python3 scripts/bench/bench-apps.py /tmp/winwait 10 "Loam=/tmp/loam-instances/bench/Loam.app/Contents/MacOS/Loam::--instance bench --vault /path/to/PerfVault10k" "Obsidian=/Applications/Obsidian.app/Contents/MacOS/Obsidian" "Notion=/Applications/Notion.app/Contents/MacOS/Notion"
python3 scripts/bench/bench-agents.py VAULT NOTION_PAGE_URL out.csv --loam /tmp/loam-instances/bench/Loam.app/Contents/Helpers/loam --runs 3
```

`raw/before-agent-harness` keeps the agent runs at commit `25f572d`, before the harness work.
