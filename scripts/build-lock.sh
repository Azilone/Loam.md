#!/usr/bin/env bash
# Runs a command holding a machine-wide Loam build lock, so builds and tests from every worktree and agent take turns
# instead of sharing the CPU (two at once each take more than twice as long). Waits for the lock, saying so.
# Nested calls (a locked script running another) go straight through.
#   scripts/build-lock.sh COMMAND [ARGS...]
# Two lanes, each one at a time: the app build (LOAM_LOCK_LANE=app: dev-refresh.sh, build-app.sh), what a person
# waits on to try a change, and everything else (tests, `make build`). An app build never queues behind a test run;
# the other lane runs at a lower priority, so the app build gets the CPU when both run.
# A script locks itself with, before any `cd`:
#   [ -n "${LOAM_BUILD_LOCKED:-}" ] || exec "$(dirname "$0")/build-lock.sh" "$0" "$@"
set -euo pipefail
[ -n "${LOAM_BUILD_LOCKED:-}" ] && exec "$@"
export LOAM_BUILD_LOCKED=1
if [ "${LOAM_LOCK_LANE:-}" = app ]; then
    lock=/tmp/loam-app-build.lock what="app build" run=()
else
    lock=/tmp/loam-build.lock what="build or test" run=(nice -n 10)
fi

if command -v lockf >/dev/null 2>&1; then
    lockf -t 0 "$lock" true 2>/dev/null || echo "build-lock: another Loam $what is running (make ps), waiting…" >&2
    exec lockf "$lock" ${run[@]+"${run[@]}"} "$@"
elif command -v flock >/dev/null 2>&1; then
    flock -n "$lock" true 2>/dev/null || echo "build-lock: another Loam $what is running (make ps), waiting…" >&2
    exec flock "$lock" ${run[@]+"${run[@]}"} "$@"
fi
exec ${run[@]+"${run[@]}"} "$@"
