#!/usr/bin/env python3
"""Times what a person feels in the app, scenario by scenario, against budgets: a guard against frame-rate regressions.

Starts a release agent instance with LOAM_FRAMES=1 (docs/PERF.md), drives it with scripts/loam-ctl, and reads the
lines its frame meter writes in the instance's app.log. For each input it measures, a line gives the longest frame in
the half second after it (the first frame's latency included) and how many of those frames came late; for a scroll,
the frames drawn each second. Each scenario runs several times; the first run (cold caches) is left out and the median
of the others is compared with its budgets: the longest frame and the late frames (or the frame rate of a scroll).
Exits 1 when a median is over budget, 2 when one is over on a machine too busy to judge (load above the cores).

    scripts/perf-ui.py                       # builds, then runs on a copy of ~/TestVault
    scripts/perf-ui.py --template ~/LoamTest-RealVault   # the scenarios that need the real vault's pages too
    scripts/perf-ui.py --no-build --runs 7 --scenario sidebar,tab
    scripts/perf-ui.py --json out.json       # the results, for a script
    scripts/perf-ui.py --no-budget           # report only

The numbers depend on the machine and on what else runs: a busy machine (another build) makes every frame late. The
load average is taken before and after; above half the cores the script reports without judging.
Clicks go by coordinates: `id:`/`label:` targets walk the accessibility tree and stall the main thread.
"""
import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CTL = os.path.join(ROOT, "scripts", "loam-ctl")
NAME = "perf-ui"
LOG = f"/tmp/loam-instances/{NAME}/app.log"
INPUT = re.compile(r"^input (.+?): first frame \+([\d.]+) ms, then (\d+) late of (\d+), longest (\d+) ms")
FRAMES = re.compile(r"^frames: (\d+) in ([\d.]+) s at (\d+) Hz expected, (\d+) late, longest (\d+) ms")

# Points of the 1300 x 850 window the script sets (content coordinates, from the top-left corner).
ALL_NOTES_ROW = "82,141"
TASKS_ROW = "82,175"
FIRST_CARD = "400,250"
CONTENT = "650,500"
GALLERY = "BASES/GALERIE DES RESSOURCES.base"
GALERIE_TAB = "348,175"  # the base's view tabs, under its title
TABLE_TAB = "407,175"

# Per scenario: the longest frame (ms) and the late frames (count, summed over the inputs a run measures), median over
# the runs; a scroll's budget is its lowest frame rate. Measured on ~/LoamTest-RealVault (a copy of the real vault) on
# 2026-11-04 with headroom. Change a budget only with a reason in the commit, as docs/PERF.md says for `make perf`.
BUDGETS = {
    "note → note": {"longest": 45, "late": 4},
    "All Notes": {"longest": 60, "late": 6},
    "scroll All Notes (fps)": {"fps": 100},
    "card → note": {"longest": 70, "late": 5},
    "back to All Notes": {"longest": 50, "late": 5},
    "All Notes ↔ Tasks": {"longest": 70, "late": 5},
    "Tasks from a note": {"longest": 80, "late": 7},
    "left sidebar, All Notes": {"longest": 50, "late": 4},
    "left sidebar, note": {"longest": 50, "late": 4},
    "right sidebar": {"longest": 50, "late": 4},
    "scroll a note (fps)": {"fps": 110},
    "new tab, Escape": {"longest": 75, "late": 6},
    "close tab": {"longest": 220, "late": 4},  # one ~150 ms frame today, a known hitch to bring down
    "quick open": {"longest": 60, "late": 6},
    "quick open typing": {"longest": 40, "late": 3},
    "typing a long note": {"longest": 45, "late": 12},
    "gallery open": {"longest": 80, "late": 6},
    "scroll gallery (fps)": {"fps": 100},
    "Galerie → Table": {"longest": 90, "late": 5},
}
# Scenarios on a page only the real vault has; skipped on another vault.
REAL_VAULT_ONLY = {"gallery open", "Galerie → Table", "scroll gallery (fps)"}


def ctl(*args, check=True):
    result = subprocess.run([CTL, "-i", NAME, *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        sys.exit(f"perf-ui: loam-ctl {' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def log_size():
    return os.path.getsize(LOG) if os.path.exists(LOG) else 0


def new_lines(offset):
    with open(LOG, encoding="utf-8", errors="replace") as handle:
        handle.seek(offset)
        return handle.read().splitlines()


def frames_after(action, wait=0.9):
    """Runs `action`, waits, and returns (longest frame in ms, late frames) over the inputs it sent, or None."""
    offset = log_size()
    action()
    time.sleep(wait)
    found = [m for m in map(INPUT.match, new_lines(offset)) if m]
    if not found:
        return None
    longest = max(max(float(m.group(2)), int(m.group(5))) for m in found)
    return {"longest": longest, "late": sum(int(m.group(3)) for m in found)}


def fps_during(action, settle=0.3):
    """Runs `action` (a scroll) and returns the lowest frame rate of the full seconds it covered."""
    offset = log_size()
    action()
    time.sleep(settle)
    rates = [int(m.group(1)) / float(m.group(2)) for m in map(FRAMES.match, new_lines(offset)) if m]
    # The frame meter only writes a second that had a late frame: a scroll without any line ran at full rate.
    return {"fps": min(rates) if rates else 120.0}


def pick_notes(vault):
    """Two notes of 2 to 12 KB, the ones nearest 5 KB, so the switch draws a screenful of real text."""
    found = []
    for folder, dirs, files in os.walk(vault):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for name in sorted(files):
            if name.endswith(".md") and not name.endswith(".excalidraw.md"):
                full = os.path.join(folder, name)
                size = os.path.getsize(full)
                if 2_000 <= size <= 12_000:
                    found.append((abs(size - 5_000), os.path.relpath(full, vault)))
    found.sort()
    if len(found) < 2:
        sys.exit("perf-ui: the vault needs two notes of 2 to 12 KB")
    return found[0][1], found[1][1]


def longest_note(vault):
    """The vault's longest note (its own Markdown, not a drawing's), where typing costs the most."""
    best = (0, None)
    for folder, dirs, files in os.walk(vault):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for name in sorted(files):
            if name.endswith(".md") and not name.endswith(".excalidraw.md"):
                full = os.path.join(folder, name)
                best = max(best, (os.path.getsize(full), os.path.relpath(full, vault)))
    return best[1]


def scenarios(vault, first, second):
    """(name, setup, action, measure) in the order they run; setup runs before each run, outside the measure."""
    pause = time.sleep
    open_first = lambda: (ctl("open", first), pause(0.8))
    open_notes = lambda: (ctl("open", "notes:"), pause(1.2))
    toggle = {"note": False, "page": False}

    def switch():
        toggle["note"] = not toggle["note"]
        ctl("open", second if toggle["note"] else first)

    def all_notes_or_tasks():
        toggle["page"] = not toggle["page"]
        ctl("click", TASKS_ROW if toggle["page"] else ALL_NOTES_ROW)

    def new_tab():
        ctl("key", "cmd+t")
        pause(0.6)
        ctl("key", "escape")

    def open_tab():
        new_tab()
        pause(0.8)

    def scroll(dy):
        def action():
            ctl("scroll", CONTENT, str(dy), "--for", "1500")
            ctl("scroll", CONTENT, str(-dy), "--for", "1500")
        return action

    def quick_open():
        ctl("key", "cmd+o")

    def quick_open_ready():
        ctl("key", "cmd+o")
        pause(0.6)

    def typing():
        # One key each 0.55 s: the meter follows one input at a time, for half a second, and `type` is not followed.
        for key in "projet":
            ctl("key", key)
            pause(0.55)

    long_note = longest_note(vault)

    def at_end_of_long_note():
        ctl("open", long_note)
        pause(1.5)
        ctl("key", "cmd+down")
        pause(0.5)

    def typing_fast():
        # As fast as loam-ctl sends keys (~8 a second): each key's line is written when the next one comes.
        for key in ["return", *"projet", "space", *"suite"]:
            ctl("key", key)

    def close_popup():
        ctl("key", "escape")
        pause(0.4)

    def gallery_ready():
        ctl("open", GALLERY)
        pause(1.0)
        ctl("click", GALERIE_TAB)
        pause(1.0)

    long_wait = lambda action: frames_after(action, wait=1.2)
    return [
        ("note → note", open_first, switch, frames_after),
        ("All Notes", open_first, lambda: ctl("open", "notes:"), long_wait),
        ("scroll All Notes (fps)", open_notes, scroll(12), fps_during),
        ("card → note", open_notes, lambda: ctl("click", FIRST_CARD), long_wait),
        ("back to All Notes", lambda: (open_notes(), ctl("click", FIRST_CARD), pause(1.0)),
         lambda: ctl("key", "cmd+["), long_wait),
        ("All Notes ↔ Tasks", None, all_notes_or_tasks, long_wait),
        ("Tasks from a note", open_first, lambda: ctl("click", TASKS_ROW), long_wait),
        ("left sidebar, All Notes", open_notes, lambda: ctl("run", "sidebar.toggle-leading"), frames_after),
        ("left sidebar, note", open_first, lambda: ctl("run", "sidebar.toggle-leading"), frames_after),
        ("right sidebar", open_first, lambda: ctl("run", "sidebar.toggle-trailing"), frames_after),
        ("scroll a note (fps)", open_first, scroll(10), fps_during),
        ("new tab, Escape", open_first, new_tab, frames_after),
        ("close tab", open_tab, lambda: ctl("key", "cmd+w"), frames_after),
        ("quick open", lambda: (open_first(), close_popup()), quick_open, frames_after),
        ("quick open typing", quick_open_ready, typing, frames_after),
        ("typing a long note", at_end_of_long_note, typing_fast, frames_after),
        ("gallery open", open_first, lambda: ctl("open", GALLERY), lambda action: frames_after(action, wait=1.5)),
        ("scroll gallery (fps)", gallery_ready, scroll(12), fps_during),
        ("Galerie → Table", gallery_ready, lambda: ctl("click", TABLE_TAB), long_wait),
    ]


def judge(name, values, scale):
    """(medians, over) for one scenario's runs; `scale` multiplies the budgets (a frame rate's divides)."""
    budget = scaled(BUDGETS[name], scale)
    medians = {key: statistics.median(v[key] for v in values) for key in budget}
    over = [key for key, limit in budget.items() if (medians[key] < limit if key == "fps" else medians[key] > limit)]
    return medians, over


def scaled(budget, scale):
    return {key: (limit / scale if key == "fps" else limit * scale) for key, limit in budget.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", type=int, default=5, help="runs per scenario after the cold one (default 5)")
    parser.add_argument("--no-build", action="store_true", help="reuse App/build/Loam.app as it is")
    parser.add_argument("--template", help="the vault to copy (default ~/TestVault)")
    parser.add_argument("--no-budget", action="store_true", help="report without failing")
    parser.add_argument("--scenario", help="only the scenarios whose name contains one of these comma-separated words")
    parser.add_argument("--json", help="also write the results to this file")
    parser.add_argument("--judge-busy", action="store_true", help="fail on a budget even when the machine is busy")
    parser.add_argument("--budget-scale", type=float, default=1.0,
                        help="multiply the budgets (0.2 checks that the guard fails)")
    args = parser.parse_args()

    command = [os.path.join(ROOT, "scripts", "agent-run.sh"), NAME, "--release", "--fresh"]
    if args.no_build:
        command.append("--no-build")
    if args.template:
        command += ["--template", os.path.expanduser(args.template)]
    env = dict(os.environ, LOAM_FRAMES="1")
    started = subprocess.run(command, env=env, capture_output=True, text=True)
    if started.returncode != 0:
        sys.exit(f"perf-ui: the instance did not start:\n{started.stderr[-2000:]}")
    vault = next((part.split("=", 1)[1] for part in started.stdout.split() if part.startswith("vault=")), None)
    if not vault:
        sys.exit("perf-ui: agent-run printed no vault")

    words = [w.strip().lower() for w in (args.scenario or "").split(",") if w.strip()]
    has_gallery = os.path.exists(os.path.join(vault, GALLERY))
    results, skipped = {}, []
    load_before = os.getloadavg()[0]
    try:
        ctl("window", "1300", "850", "--front")
        first, second = pick_notes(vault)
        ctl("open", first)
        time.sleep(1.5)
        for name, setup, action, measure in scenarios(vault, first, second):
            if words and not any(w in name.lower() for w in words):
                continue
            if name in REAL_VAULT_ONLY and not has_gallery:
                skipped.append(name)
                continue
            rounds = max(2, args.runs // 2) if name.endswith("(fps)") else args.runs
            values = []
            for _ in range(rounds + 1):
                if setup:
                    setup()
                values.append(measure(action))
            results[name] = [v for v in values[1:] if v is not None]
            ctl("key", "escape", check=False)
            time.sleep(0.3)
    finally:
        ctl("quit", check=False)
    load = max(load_before, os.getloadavg()[0])
    busy = load > (os.cpu_count() or 8)

    failed, report = [], {}
    print(f"perf-ui: {args.runs} runs each after a cold one; load average {load:.1f} on {os.cpu_count()} cores")
    print(f"{'scenario':26} {'longest':>9} {'budget':>7} {'late':>5} {'budget':>6}")
    for name, values in results.items():
        if not values:
            print(f"{name:26} {'—':>9}  no measure")
            failed.append(name)
            report[name] = {"runs": [], "over": ["no measure"]}
            continue
        medians, over = judge(name, values, args.budget_scale)
        budget = scaled(BUDGETS[name], args.budget_scale)
        mark = "  OVER" if over else ""
        if "fps" in budget:
            print(f"{name:26} {medians['fps']:>5.0f} fps {budget['fps']:>3.0f} fps{'':>13}{mark}")
        else:
            print(f"{name:26} {medians['longest']:>6.0f} ms {budget['longest']:>4.0f} ms "
                  f"{medians['late']:>5.0f} {budget['late']:>6.0f}{mark}")
        report[name] = {"runs": values, "median": medians, "budget": budget, "over": over}
        if over:
            failed.append(name)
    if skipped:
        print(f"perf-ui: skipped (the vault has no {GALLERY}): {', '.join(skipped)}")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump({"load": load, "cores": os.cpu_count(), "busy": busy, "runs": args.runs,
                       "scenarios": report, "failed": failed}, handle, ensure_ascii=False, indent=2)
    if args.no_budget:
        return
    if failed and busy and not args.judge_busy:
        # A busy machine only makes frames later: a pass still counts, a miss may not be the app's.
        print(f"perf-ui: over budget on a busy machine (load above the {os.cpu_count()} cores): {', '.join(failed)}. "
              "Frames come late for reasons outside the app, so nothing is judged: rerun when it is idle, or pass "
              "--judge-busy.")
        sys.exit(2)
    if failed:
        print(f"perf-ui: over budget: {', '.join(failed)}")
        sys.exit(1)
    if busy:
        print("perf-ui: the machine was busy; every scenario within budget all the same")
        return
    print("perf-ui: every scenario within budget")


if __name__ == "__main__":
    main()
