#!/usr/bin/env python3
"""Times what a person feels in the app: a note opened, the sidebars, All Notes, a new tab, Quick Open, scrolling.

Starts a release agent instance with LOAM_FRAMES=1 (docs/PERF.md), drives it with scripts/loam-ctl, and reads the
lines its frame meter writes in the instance's app.log: for each action, the longest frame in the half second after
it; for a scroll, the frames drawn each second. Each action runs several times; the first run (cold caches) is left
out and the median is compared with its budget. Exits 1 when a median is over budget. "late" is the share of the
frames after each input that came late (smoothness of the animation that follows), reported, not budgeted.

    scripts/perf-ui.py                       # builds, then runs on a copy of ~/TestVault
    scripts/perf-ui.py --no-build --runs 7
    scripts/perf-ui.py --template DIR        # another vault, copied first (never a real vault in place)
    scripts/perf-ui.py --no-budget           # report only

The numbers depend on the machine and on what else runs: a busy machine (another build) makes every frame late.
The script prints the load average next to the results; rerun when it is high.
"""
import argparse
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

# Longest frame after the action, median over the runs, in milliseconds (frames per second for a scroll). Change a
# budget only with a reason in the commit, as docs/PERF.md says for `make perf`.
BUDGETS = {
    "note → note": 45,
    "All Notes": 150,
    "right sidebar": 50,
    "left sidebar": 50,
    "new tab": 75,
    "quick open": 60,
    "scroll All Notes (fps)": 100,
    "scroll a note (fps)": 110,
}


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


def longest_after(action, wait=0.9):
    """Runs `action`, waits, and returns the longest frame after the inputs it sent (None if none came)."""
    offset = log_size()
    action()
    time.sleep(wait)
    found = [INPUT.match(line) for line in new_lines(offset)]
    found = [m for m in found if m]
    if not found:
        return None
    # The longest frame, and the share of the frames in the half second after each input that came late: a smooth
    # animation has none.
    late = sum(int(m.group(3)) for m in found) / max(1, sum(int(m.group(4)) for m in found))
    return max(int(m.group(5)) for m in found), late


def fps_during(action, settle=0.3):
    """Runs `action` (a scroll) and returns the frames per second of the full seconds it covered."""
    offset = log_size()
    action()
    time.sleep(settle)
    rates = []
    for line in new_lines(offset):
        m = FRAMES.match(line)
        if m:
            rates.append(int(m.group(1)) / float(m.group(2)))
    # The frame meter only writes a second that had a late frame: a scroll without any line ran at full rate.
    return min(rates) if rates else 120.0


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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", type=int, default=5, help="runs per action after the cold one (default 5)")
    parser.add_argument("--no-build", action="store_true", help="reuse App/build/Loam.app as it is")
    parser.add_argument("--template", help="the vault to copy (default ~/TestVault)")
    parser.add_argument("--no-budget", action="store_true", help="report without failing")
    args = parser.parse_args()

    command = [os.path.join(ROOT, "scripts", "agent-run.sh"), NAME, "--release", "--fresh"]
    if args.no_build:
        command.append("--no-build")
    if args.template:
        command += ["--template", args.template]
    env = dict(os.environ, LOAM_FRAMES="1")
    started = subprocess.run(command, env=env, capture_output=True, text=True)
    if started.returncode != 0:
        sys.exit(f"perf-ui: the instance did not start:\n{started.stderr[-2000:]}")
    vault = next((part.split("=", 1)[1] for part in started.stdout.split() if part.startswith("vault=")), None)
    if not vault:
        sys.exit("perf-ui: agent-run printed no vault")

    try:
        ctl("window", "1300", "850", "--front")
        first, second = pick_notes(vault)
        ctl("open", first)
        time.sleep(1.5)
        results = {}

        def series(name, action, measure=longest_after, rounds=None):
            values = [measure(action) for _ in range((rounds or args.runs) + 1)][1:]
            results[name] = [v for v in values if v is not None]

        toggle = {"note": False}

        def switch():
            toggle["note"] = not toggle["note"]
            ctl("open", second if toggle["note"] else first)

        series("note → note", switch)

        def all_notes():
            ctl("open", first)
            time.sleep(0.6)
            ctl("open", "notes:")

        series("All Notes", all_notes, measure=lambda action: longest_after(action, wait=1.2))

        def scroll_grid():
            ctl("scroll", "650,500", "12", "--for", "1500")
            ctl("scroll", "650,500", "-12", "--for", "1500")

        series("scroll All Notes (fps)", scroll_grid, measure=fps_during, rounds=max(2, args.runs // 2))

        ctl("open", first)
        time.sleep(0.8)

        def scroll_note():
            ctl("scroll", "650,500", "10", "--for", "1500")
            ctl("scroll", "650,500", "-10", "--for", "1500")

        series("scroll a note (fps)", scroll_note, measure=fps_during, rounds=max(2, args.runs // 2))
        series("right sidebar", lambda: ctl("run", "sidebar.toggle-trailing"))
        series("left sidebar", lambda: ctl("run", "sidebar.toggle-leading"))
        # Both sidebars back as they were (an even number of toggles leaves them so only for an even count).
        if (args.runs + 1) % 2:
            ctl("run", "sidebar.toggle-trailing")
            ctl("run", "sidebar.toggle-leading")

        def new_tab():
            ctl("key", "cmd+t")
            time.sleep(0.7)
            ctl("key", "escape")
            time.sleep(0.2)
            ctl("key", "cmd+w")

        series("new tab", new_tab, measure=lambda action: longest_after(action, wait=0.9))

        def quick_open():
            ctl("key", "escape")
            time.sleep(0.3)
            ctl("key", "cmd+o")

        series("quick open", quick_open)
        ctl("key", "escape")
    finally:
        ctl("quit", check=False)

    load = os.getloadavg()[0]
    failed = []
    print(f"perf-ui: {args.runs} runs each after a cold one; load average {load:.1f} on {os.cpu_count()} cores")
    print(f"{'action':26} {'median':>8} {'worst':>8} {'budget':>8} {'late':>6}")
    for name, values in results.items():
        budget = BUDGETS[name]
        if not values:
            print(f"{name:26} {'—':>8} {'—':>8} {budget:>8}  no measure")
            failed.append(name)
            continue
        lates = [v[1] for v in values if isinstance(v, tuple)]
        values = [v[0] if isinstance(v, tuple) else v for v in values]
        late = f"{statistics.median(lates) * 100:>5.0f}%" if lates else ""
        median = statistics.median(values)
        is_rate = name.endswith("(fps)")
        worst = min(values) if is_rate else max(values)
        over = median < budget if is_rate else median > budget
        unit = " fps" if is_rate else " ms"
        mark = "  OVER" if over else ""
        print(f"{name:26} {median:>5.0f}{unit:3} {worst:>5.0f}{unit:3} {budget:>5}{unit:3} {late:>6}{mark}")
        if over:
            failed.append(name)
    if load > (os.cpu_count() or 8) * 0.5:
        print("perf-ui: the machine is busy; frames come late for reasons outside the app. Rerun when it is idle.")
    if failed and not args.no_budget:
        print(f"perf-ui: over budget: {', '.join(failed)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
