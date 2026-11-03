#!/usr/bin/env bash
# Builds Loam and starts an isolated instance an agent can drive without the screen: its own bundle id, preferences,
# window title, vault copy and control socket. Several instances (and several agents) run side by side.
#
# Usage: agent-run.sh NAME [--vault DIR | --template DIR] [--release] [--no-build] [--fresh] [--no-badge]
#
#   NAME          the instance: letters, digits, . _ - (at most 32). Starting a name again restarts that instance.
#   --template D  the vault to copy (default ~/TestVault if it exists, else a demo vault from make-test-vault.sh)
#   --vault D     use this folder as the vault, as it is (no copy)
#   --release     an optimised build with the debug channel (-DLOAM_AGENT_BRIDGE); default is the debug configuration
#   --no-build    reuse App/build/Loam.app as it is
#   --fresh       forget the instance's preferences (window layout, last vault) before starting
#   --no-badge    no build badge in the window (pictures of the app, as scripts/onboarding-shots.sh takes)
#
# The last line printed is `socket=<path>`. Then:   scripts/loam-ctl -i NAME shot /tmp/a.png   (docs/AGENT-TESTING.md)
# Everything lives in /tmp/loam-instances/NAME (LOAM_INSTANCES_DIR): Loam.app, vault/, app.log, ctl.sock. Stop it with
# `scripts/loam-ctl -i NAME quit`; this script never kills a process it did not start.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

name="${1:-}"
[[ -n "$name" && "$name" != -* ]] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift
[[ "$name" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,31}$ ]] || { echo "agent-run: bad instance name '$name'" >&2; exit 2; }

template="" vault="" config=debug build=1 fresh=0 badge=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --template) template="${2:?--template needs a folder}"; shift 2 ;;
        --vault) vault="${2:?--vault needs a folder}"; shift 2 ;;
        --release) config=release; shift ;;
        --no-build) build=0; shift ;;
        --fresh) fresh=1; shift ;;
        --no-badge) badge=0; shift ;;
        *) echo "agent-run: unknown option $1" >&2; exit 2 ;;
    esac
done

base="${LOAM_INSTANCES_DIR:-/tmp/loam-instances}"
dir="$base/$name"
mkdir -p "$base"
chmod 700 "$base" 2>/dev/null || true

# One build at a time per checkout: two agents in one worktree would write the same .build folders.
lock="$base/.build-$(printf '%s' "$root" | shasum | cut -c1-10).lock"
if [[ $build -eq 1 ]]; then
    waited=0
    until mkdir "$lock" 2>/dev/null; do
        # A lock whose owner is gone (killed build) is taken over.
        owner="$(cat "$lock/pid" 2>/dev/null || true)"
        if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$lock"; continue; fi
        [[ $waited -eq 0 ]] && echo "agent-run: another build of this checkout is running, waiting..." >&2
        waited=1; sleep 2
    done
    echo $$ > "$lock/pid"
    trap 'rm -rf "$lock"' EXIT
    if [[ "$config" == release ]]; then
        LOAM_SWIFT_FLAGS="-Xswiftc -DLOAM_AGENT_BRIDGE" ./scripts/build-app.sh release >&2
    else
        # Fast path first (dev-refresh.sh: only the Swift code is rebuilt); exit 3 means the bundle needs a full build.
        rc=0; ./scripts/dev-refresh.sh >&2 || rc=$?
        if [[ $rc -eq 3 ]]; then ./scripts/build-app.sh debug >&2; elif [[ $rc -ne 0 ]]; then exit $rc; fi
    fi
    rm -rf "$lock"; trap - EXIT
fi
[[ -d App/build/Loam.app ]] || { echo "agent-run: App/build/Loam.app is missing (drop --no-build)" >&2; exit 1; }

# Stop the previous run of this name: through its socket, so it saves and quits; a pid only if it ignores that.
if [[ -S "$dir/ctl.sock" ]]; then
    ./scripts/loam-ctl -i "$name" quit >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do [[ -S "$dir/ctl.sock" ]] || break; sleep 0.2; done
fi
if [[ -f "$dir/pid" ]]; then
    old="$(cat "$dir/pid")"
    if kill -0 "$old" 2>/dev/null && [[ "$(ps -o command= -p "$old" 2>/dev/null)" == *"/$name/Loam.app/"* ]]; then kill "$old" 2>/dev/null || true; sleep 1; fi
fi
rm -f "$dir/ctl.sock" "$dir/state.json" "$dir/pid"
mkdir -p "$dir"
chmod 700 "$dir"
# Which checkout built it, for scripts/loam-ps.
printf '%s\n' "$root" > "$dir/source"

# The app, copied (a clone on APFS: no extra disk) with its own identity: own preferences, own window restoration.
bundle_id="com.azilone.loam.agent.$(printf '%s' "$name" | tr -c 'A-Za-z0-9.-\n' '-')"
if [[ $fresh -eq 1 ]]; then defaults delete "$bundle_id" >/dev/null 2>&1 || true; fi
rm -rf "$dir/Loam.app"
cp -cR App/build/Loam.app "$dir/Loam.app" 2>/dev/null || cp -R App/build/Loam.app "$dir/Loam.app"
plist="$dir/Loam.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Loam-$name" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Loam [$name]" "$plist"
# The badge in its window (BuildBadge): the instance, then the worktree or branch it was built from.
case "$root" in */.claude/worktrees/*) built_from="${root##*/}" ;; *) built_from="$(git branch --show-current 2>/dev/null || echo dev)" ;; esac
/usr/libexec/PlistBuddy -c "Delete :LoamBuildLabel" "$plist" >/dev/null 2>&1 || true
[[ $badge -eq 1 ]] && /usr/libexec/PlistBuddy -c "Add :LoamBuildLabel string $name · $built_from" "$plist"
codesign --force --sign - --entitlements App/Loam.entitlements "$dir/Loam.app" >/dev/null 2>&1

# The vault: a copy of the template, so every run starts from the same notes and nothing real is ever touched.
if [[ -z "$vault" ]]; then
    if [[ -z "$template" ]]; then
        template="$HOME/TestVault"
        if [[ ! -d "$template" ]]; then
            template="$base/.template-vault"
            [[ -d "$template" ]] || ./scripts/make-test-vault.sh "$template" >&2
        fi
    fi
    case "$template" in *"Mobile Documents"*|*"iCloud~md~obsidian"*) echo "agent-run: refusing an iCloud vault as template" >&2; exit 1 ;; esac
    [[ -d "$template" ]] || { echo "agent-run: no template vault at $template" >&2; exit 1; }
    rm -rf "$dir/vault"
    cp -cR "$template" "$dir/vault" 2>/dev/null || cp -R "$template" "$dir/vault"
    # What the template's own app run left behind (open tabs, locks) is not part of the starting point.
    rm -rf "$dir/vault/.loam/layout" 2>/dev/null || true
    vault="$dir/vault"
fi

# In the background, from the executable itself: no focus is taken, LaunchServices never merges it with another run.
LOAM_INSTANCE="$name" LOAM_INSTANCES_DIR="$base" nohup "$dir/Loam.app/Contents/MacOS/Loam" --instance "$name" --vault "$vault" \
    > "$dir/app.log" 2>&1 < /dev/null &
echo $! > "$dir/pid"
disown

for _ in $(seq 1 150); do
    if [[ -S "$dir/ctl.sock" ]] && ./scripts/loam-ctl -i "$name" ping >/dev/null 2>&1; then
        echo "instance=$name pid=$(cat "$dir/pid") config=$config vault=$vault log=$dir/app.log"
        echo "socket=$dir/ctl.sock"
        exit 0
    fi
    kill -0 "$(cat "$dir/pid")" 2>/dev/null || { echo "agent-run: the app exited at start:" >&2; tail -20 "$dir/app.log" >&2; exit 1; }
    sleep 0.4
done
echo "agent-run: no answer on $dir/ctl.sock after 60 s; see $dir/app.log" >&2
exit 1
