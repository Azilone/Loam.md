#!/usr/bin/env python3
"""Cold start (ms to first window) and memory at rest (MB, process tree RSS after IDLE s) for note apps.

Usage: bench-apps.py WINWAIT_BIN RUNS APP=EXECUTABLE[::ARGS] ...
Each run: kill the app, wait, launch the executable directly, time its first on-screen window, sample RSS.
The first run of each app is a warm-up and is dropped. Prints a CSV line per run and medians.
"""
import statistics
import subprocess
import sys
import time

IDLE = 20


def tree_rss_mb(root):
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,rss="], capture_output=True, text=True).stdout.split()
    rows = [(int(out[i]), int(out[i + 1]), int(out[i + 2])) for i in range(0, len(out), 3)]
    pids, total, grew = {root}, 0, True
    while grew:
        grew = False
        for pid, ppid, _ in rows:
            if ppid in pids and pid not in pids:
                pids.add(pid)
                grew = True
    return sum(rss for pid, _, rss in rows if pid in pids) / 1024


def main():
    winwait, runs, apps = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
    results = {}
    for spec in apps:
        name, cmd = spec.split("=", 1)
        exe, _, extra = cmd.partition("::")
        argv = [exe] + (extra.split() if extra else [])
        starts, mems = [], []
        for run in range(runs + 1):
            subprocess.run(["pkill", "-f", exe], capture_output=True)
            time.sleep(3)
            t0 = time.time() * 1000
            proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            ms = int(subprocess.run([winwait, str(proc.pid), str(t0), "20000"], capture_output=True, text=True).stdout)
            time.sleep(IDLE)
            mb = tree_rss_mb(proc.pid)
            print(f"{name},{run},{ms},{mb:.0f}", flush=True)
            if run > 0:
                starts.append(ms)
                mems.append(mb)
        subprocess.run(["pkill", "-f", exe], capture_output=True)
        results[name] = (statistics.median(starts), statistics.median(mems))
    for name, (s, m) in results.items():
        print(f"MEDIAN {name}: start {s:.0f} ms, memory {m:.0f} MB")


if __name__ == "__main__":
    main()
