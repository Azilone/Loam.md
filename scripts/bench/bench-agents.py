#!/usr/bin/env python3
"""Tokens and time per task for a coding agent asked about the same notes, as a user would ask it.

Three setups, nothing scripted for the agent: it picks its own tools.
  loam      the vault folder, with the `loam` CLI on the PATH and the loam skill installed (`loam skill install`)
  obsidian  the same folder as plain Markdown files, the agent's own file tools (how an agent reads an Obsidian vault)
  notion    the same notes as Notion pages, through Notion's MCP server

Usage: bench-agents.py VAULT NOTION_PAGE_URL OUT.csv [--loam PATH] [--model M] [--effort E] [--runs N]
                       [--only N] [--setups A,B]
Each task runs `--runs` times per setup with `claude -p --output-format json`, setups interleaved. Tokens: input
(cache included) + output. Task -1 is the baseline: the same setup asked for nothing, whose tokens every task pays.
`correct` checks the whole answer names the expected facts.

The user's own Claude Code settings stay out (`--setting-sources project`: no global CLAUDE.md, hooks or skills).
Each file setup works in its own copy of the vault; the loam copy carries the loam skill in `.claude/skills/loam`.
"""
import argparse
import csv
import json
import os
import shutil
import subprocess
import tempfile
import time

TASKS = [
    ("How much does my course cost right now?", ["497"]),
    ("Which of my clients are still open?", ["Atelier Nord", "Studio Kappa", "Orbit Labs"]),
    ("What did I decide about pricing?", ["397", "72"]),
    ("Which notes link to Beta?", ["kickoff", "onboarding", "2026-10-20"]),
    ("What ideas did I have about agents?", ["inbox", "weekly review", "memory"]),
    ("What did I ship between October 19 and 25?", ["0.9", "0.11", "0.13", "0.15"]),
]

BASELINE = "Reply with just: ready."
FILE_TOOLS = "Read,Grep,Glob,LS"
SKILL = os.path.expanduser("~/.claude/skills/loam")


def copy_vault(vault, with_skill):
    folder = os.path.join(tempfile.mkdtemp(), os.path.basename(vault))
    shutil.copytree(vault, folder, ignore=shutil.ignore_patterns(".loam", ".obsidian", ".claude"))
    if with_skill:
        shutil.copytree(SKILL, os.path.join(folder, ".claude/skills/loam"))
    return folder


def setups(vault, notion_url, loam_bin):
    return {
        "loam": dict(cwd=copy_vault(vault, True), tools=["--allowedTools", FILE_TOOLS + ",Skill,Bash(loam:*)"],
                     note="My notes are in this folder, a Loam vault.",
                     path=os.path.dirname(loam_bin)),
        "obsidian": dict(cwd=copy_vault(vault, False), tools=["--allowedTools", FILE_TOOLS],
                         note="My notes are in this folder, an Obsidian vault."),
        "notion": dict(cwd=tempfile.mkdtemp(), tools=["--allowedTools", "mcp__claude_ai_Notion"],
                       note=f"My notes are in Notion, under the page {notion_url}."),
    }


def ask(name, setup, run, index, task, expected, args):
    env = dict(os.environ)
    if "path" in setup:
        env["PATH"] = setup["path"] + ":" + env["PATH"]
    prompt = task if index < 0 else f"{setup['note']} {task}"
    command = ["claude", "-p", prompt, "--model", args.model, "--effort", args.effort, "--output-format", "json",
               "--no-session-persistence", "--setting-sources", "project", *setup["tools"]]
    start = time.time()
    try:
        done = subprocess.run(command, cwd=setup["cwd"], capture_output=True, text=True, env=env, timeout=600)
        output = done.stdout + done.stderr
        result = json.loads(done.stdout)
    except subprocess.TimeoutExpired:
        output, result = "timeout", {}
    except json.JSONDecodeError:
        result = {"result": output[-400:]}
    seconds = time.time() - start
    usage = result.get("usage", {})
    tokens = sum(usage.get(key, 0) for key in
                 ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"))
    answer = result.get("result", "")
    row = dict(setup=name, run=run, task=index, tokens=tokens, seconds=round(seconds, 1),
               turns=result.get("num_turns"), cost=result.get("total_cost_usd"),
               correct=all(fact.lower() in answer.lower() for fact in expected),
               answer=answer.replace("\n", " "))
    print(json.dumps({k: v for k, v in row.items() if k != "answer"}), flush=True)
    return row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("vault")
    parser.add_argument("notion")
    parser.add_argument("out")
    parser.add_argument("--loam", default="loam")
    parser.add_argument("--model", default="claude-haiku-5-5")
    parser.add_argument("--effort", default="medium")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--only", type=int)
    parser.add_argument("--setups", default="loam,obsidian,notion")
    args = parser.parse_args()
    chosen = {name: setup for name, setup in setups(os.path.abspath(args.vault), args.notion, args.loam).items()
              if name in args.setups.split(",")}
    tasks = [(-1, BASELINE, [])] + [(index, task, expected) for index, (task, expected) in enumerate(TASKS)
                                     if args.only is None or index == args.only]
    rows = []
    for run in range(args.runs):
        for index, task, expected in tasks:
            for name, setup in chosen.items():
                rows.append(ask(name, setup, run, index, task, expected, args))
    with open(args.out, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    main()
