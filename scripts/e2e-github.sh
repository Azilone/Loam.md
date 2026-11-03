#!/usr/bin/env bash
# End to end on the real GitHub: a Mac, a second Mac and an agent sync one encrypted vault through a new private
# repository, then everything that can go wrong is tried, and every clone is checked for loss and corruption.
#
#   scripts/e2e-github.sh            needs gh signed in (repo scope); makes Azilone/loam-e2e-<time>, private
#
# The devices are folders on this Mac, each with its own keys, config and SSH key, using the `loam` command line:
# the same code the app and an agent's Linux machine run. Prints PASS/FAIL per check; exits 1 on any failure.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$root/CLI" --product loam >/dev/null
loam="$(swift build --package-path "$root/CLI" --show-bin-path)/loam"
work="$(mktemp -d)/e2e"
mkdir -p "$work"
id="e2e$(date +%H%M%S)"
token="$(gh auth token)"
failures=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

# A device: its folder, keys and config, apart from the others. `mac` devices sign in to GitHub with the token.
device() {
  local name="$1" kind="$2"
  shift 2
  local env=(LOAM_KEY_DIR="$work/$name-keys" XDG_CONFIG_HOME="$work/$name-config" LOAM_CRYPT_TOOL="$loam crypt")
  [ "$kind" = mac ] && env+=(LOAM_GITHUB_TOKEN="$token")
  env "${env[@]}" "$loam" --vault "$work/$name" "$@"
}
mac() { device "$id" mac "$@"; }
mac2() { device mac2 mac "$@"; }
agent() { device agent agent "$@"; }

notes_ok() {  # no conflict markers, no ciphertext in a vault's notes
  ! grep -rl --include='*.md' -e '^<<<<<<< ' -e 'LOAMCRYPT' "$work/$1" >/dev/null 2>&1
}
remote_encrypted() {  # every file on GitHub's main is Loam ciphertext (the workflow's own check)
  local clone="$work/check-$RANDOM"
  git clone -q "https://x-access-token:$token@github.com/Azilone/loam-$id.git" "$clone" 2>/dev/null
  (cd "$clone" && bash -c "$(sed -n '/static let checkScript = #"""/,/"""#/p' "$root/Sources/Plugins/GitSync/RemoteGuard.swift" | sed '1d;$d')" >/dev/null)
}
fsck_ok() { git -C "$work/$1" fsck --no-progress >/dev/null 2>&1; }

echo "== Set up: the Mac, in one command (Settings > Connect GitHub)"
mkdir -p "$work/$id/Ideas" "$work/$id/Daily"
printf '# Plan\none\ntwo\nthree\n' > "$work/$id/Plan.md"
printf 'secret idea\n' > "$work/$id/Ideas/Secret.md"
for day in 01 02 03 04 05 06 07 08 09 10; do printf 'day %s\n' "$day" > "$work/$id/Daily/2026-10-$day.md"; done
check "the Mac sets up its private, encrypted repository" bash -c "$(declare -f device mac); $(declare -p work id loam token); mac sync.github encrypt=true | grep -q Synced"
check "the repository is private" test "$(gh repo view "Azilone/loam-$id" --json visibility -q .visibility)" = PRIVATE
check "GitHub only holds ciphertext" remote_encrypted

echo "== An agent joins with its code"
code="$(mac sync.connect agent=research | grep -o 'loam-connect:[^ ]*')"  # the code, out of the install line
mkdir -p "$work/agent"
check "the agent joins" bash -c "$(declare -f device agent); $(declare -p work loam token); LOAM_CONNECT='$code' agent sync.join | grep -q Synced"
check "the agent reads the notes decrypted" grep -q 'secret idea' "$work/agent/Ideas/Secret.md"
check "the agent's settings made no conflict copy" test -z "$(find "$work/agent" -name '*conflict*')"

echo "== Edits on both sides"
printf '# Plan\none\ntwo\nthree\nfrom the agent\n' > "$work/agent/Plan.md"
printf 'agent note\n' > "$work/agent/Ideas/Agent.md"
agent sync.now >/dev/null
printf '# Plan (Mac)\none\ntwo\nthree\n' > "$work/$id/Plan.md"
out="$(mac sync.now)"
check "different lines merge" grep -q 'from the agent' "$work/$id/Plan.md"
check "the Mac says the agent changed notes" grep -q 'research changed' <<<"$out"
check "the Mac has the agent's note" grep -q 'agent note' "$work/$id/Ideas/Agent.md"

printf 'Mac version\n' > "$work/$id/Ideas/Secret.md"
mac sync.now >/dev/null
printf 'agent version\n' > "$work/agent/Ideas/Secret.md"
agent sync.now >/dev/null
mac sync.now >/dev/null
check "the same line on both sides keeps both versions" bash -c "grep -q 'agent version' '$work/agent/Ideas/Secret.md' && ls '$work/agent/Ideas/' | grep -q conflict"
check "no conflict markers anywhere" bash -c "$(declare -f notes_ok); $(declare -p work); notes_ok '$id' && notes_ok agent"

echo "== A second Mac joins with a code"
mcode="$(mac sync.connect device=Studio)"
mkdir -p "$work/mac2"
check "the second Mac joins" bash -c "$(declare -f device mac2); $(declare -p work loam token); mac2 sync.join code='$mcode' | grep -q Synced"
check "it has every note" test "$(find "$work/mac2" -name '*.md' -not -path '*/.git/*' | wc -l)" -ge 13

echo "== Guards"
for n in $(seq 1 60); do printf 'x\n' > "$work/agent/Daily/bulk-$n.md"; done
check "an agent changing too many files pauses" bash -c "$(declare -f device agent); $(declare -p work loam token); agent sync.now | grep -q 'over this device'"
rm -f "$work"/agent/Daily/bulk-*.md

sleep 65  # so "since=1m" covers only the deletion below
rm -f "$work"/agent/Daily/2026-10-0*.md
agent sync.now >/dev/null
mac sync.now >/dev/null
check "undo brings back what the agent deleted" bash -c "$(declare -f device mac); $(declare -p work id loam token); mac sync.undo device=research since=1m >/dev/null; test -f '$work/$id/Daily/2026-10-01.md'"

echo "== An agent without Loam pushes plain text"
plain="$work/plain-$RANDOM"
git clone -q "https://x-access-token:$token@github.com/Azilone/loam-$id.git" "$plain" 2>/dev/null
printf 'plain text from a tool without Loam\n' > "$plain/Leak.md"
git -C "$plain" add Leak.md && git -C "$plain" commit -qm "plain tool" && git -C "$plain" push -q 2>/dev/null
out="$(mac sync.now)"
check "the Mac stops on plain text" grep -q 'unencrypted' <<<"$out"
check "GitHub's check catches it" bash -c "! ( $(declare -f remote_encrypted); $(declare -p work id token root); remote_encrypted )"
check "the Mac takes it and encrypts it again" bash -c "$(declare -f device mac); $(declare -p work id loam token); mac sync.now confirm=plain-incoming | grep -q Synced"
check "the leak is reported" bash -c "$(declare -f device mac); $(declare -p work id loam token); mac sync.leak.report | grep -q Leak.md"
check "GitHub only holds ciphertext again" remote_encrypted

echo "== A tool without the key writes over ciphertext"
git -C "$plain" pull -q 2>/dev/null
printf 'garbage over the noise\n' >> "$plain/Plan.md"
git -C "$plain" commit -qam "broken tool" && git -C "$plain" push -q 2>/dev/null
mac sync.now > "$work/out.txt"
check "the Mac stops and merges nothing" bash -c "grep -q 'cannot be opened\|unencrypted' '$work/out.txt' && ! grep -q garbage '$work/$id/Plan.md'"
git -C "$plain" revert --no-edit HEAD >/dev/null
for try in 1 2 3; do git -C "$plain" push -q 2>"$work/push.txt" && break; cat "$work/push.txt"; sleep 3; done
check "after a revert the Mac syncs again" bash -c "$(declare -f device mac); $(declare -p work id loam token); mac sync.now | grep -q Synced"

echo "== An interrupted sync"
printf 'during a kill\n' > "$work/agent/Ideas/Killed.md"
( agent sync.now >/dev/null 2>&1 & pid=$!; sleep 0.4; kill -9 "$pid" 2>/dev/null ) ; sleep 1
rm -f "$work/agent/.git/index.lock"
check "the next sync recovers" bash -c "$(declare -f device agent); $(declare -p work loam token); agent sync.now | grep -q Synced"
check "the agent's repository is sound" fsck_ok agent

echo "== Removing the agent"
mac sync.agents agent=research remove=true >/dev/null
sleep 3
printf 'after removal\n' > "$work/agent/Ideas/After.md"
agent sync.now > "$work/out.txt" 2>&1
check "the removed agent is told its access is gone" grep -q "refused this device's access" "$work/out.txt"
check "GitHub never got its change" bash -c "! gh api repos/Azilone/loam-$id/contents/Ideas/After.md >/dev/null 2>&1"

echo "== Final state"
mac sync.now >/dev/null; mac2 sync.now >/dev/null; mac sync.now >/dev/null
check "both Macs have the same notes" diff -rq -x .git "$work/$id" "$work/mac2"
check "no markers or ciphertext in any vault" bash -c "$(declare -f notes_ok); $(declare -p work id); notes_ok '$id' && notes_ok mac2 && notes_ok agent"
check "every repository is sound" bash -c "$(declare -f fsck_ok); $(declare -p work id); fsck_ok '$id' && fsck_ok mac2"
check "GitHub only holds ciphertext" remote_encrypted

echo
echo "Repository: https://github.com/Azilone/loam-$id (private; delete it with: gh repo delete Azilone/loam-$id)"
echo "Folders: $work"
[ "$failures" -eq 0 ] && echo "All passed." || { echo "$failures failed."; exit 1; }
