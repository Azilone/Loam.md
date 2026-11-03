#!/usr/bin/env bash
# A real run of the agent test bench (docs/AGENT-TESTING.md): starts an isolated instance, opens a note, types `> a`
# and presses Return twice, reads the editor back, saves a picture of the instance's window only, and stops it.
#
# Usage: agent-demo.sh [--no-build] [OUT.png]      (default OUT: /tmp/loam-instances/demo-quote/quote.png)
set -euo pipefail
cd "$(dirname "$0")/.."

args=()
[[ "${1:-}" == "--no-build" ]] && { args+=(--no-build); shift; }
name="demo-quote"
base="${LOAM_INSTANCES_DIR:-/tmp/loam-instances}"
out="${1:-$base/$name/quote.png}"

./scripts/agent-run.sh "$name" ${args[@]+"${args[@]}"} | tail -2
ctl() { ./scripts/loam-ctl -i "$name" "$@"; }
trap 'ctl quit >/dev/null 2>&1 || true' EXIT

# The instance's vault is its own copy: a fresh note there changes nothing real.
printf '' > "$base/$name/vault/Agent demo.md"

ctl script - <<SCENARIO
open "Agent demo.md"
wait 300
type > a
key return
key return
wait 300
shot "$out"
SCENARIO

echo "editor text after '> a', Return, Return:"
ctl editor | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d["text"])); print("selection", d["selection"])'
echo "picture: $out"
