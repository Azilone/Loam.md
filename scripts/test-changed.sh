#!/usr/bin/env bash
# Runs only the test targets touched by the working tree's changes (against BASE, default HEAD, plus untracked files):
# a test target runs when one of its own files changed or when it depends directly on a target whose sources changed.
# A change to a Package.swift or to scripts/ runs everything. `make test` stays the full run before a change is done.
#   scripts/test-changed.sh [BASE]
set -euo pipefail
[ -n "${LOAM_BUILD_LOCKED:-}" ] || exec "$(dirname "$0")/build-lock.sh" "$0" "$@"
cd "$(dirname "$0")/.."
base="${1:-HEAD}"

changed=$( { git diff --name-only "$base"; git ls-files --others --exclude-standard; } | sort -u)
if [ -z "$changed" ]; then echo "test-changed: no changes against $base"; exit 0; fi

all=0
grep -qE '(^|/)Package\.swift$|^scripts/' <<<"$changed" && all=1

# The slow end-to-end plugin builds (PluginBuildTests, ~3 min) run only when the CLI or the plugin SDK changed.
grep -qE '^(CLI/|Sources/(LoamCLI|PluginKit)/|Tests/LoamCLITests/PluginBuildTests|scripts/build-|Package\.swift$)' \
    <<<"$changed" || export LOAM_SKIP_SLOW=1

# Prints the test targets of the package in $1 (relative path, "." for the root) that the changes reach.
select_tests() {
    local dir="$1" prefix json
    [ "$dir" = "." ] && prefix="" || prefix="$dir/"
    json=$(swift package --package-path "$dir" dump-package 2>/dev/null)
    jq -r --arg prefix "$prefix" --argjson all "$all" --arg changed "$changed" '
        ($changed | split("\n")) as $files
        | def touched($path): any($files[]; startswith($prefix + $path + "/"));
          def path_of: .path // (if .type == "test" then "Tests/" else "Sources/" end + .name);
        [.targets[] | select(.type != "test") | select(touched(path_of)) | .name] as $hit
        | .targets[] | select(.type == "test")
        | select($all == 1 or touched(path_of)
                 or any(.dependencies[]; ((.byName // .target // [null])[0]) as $d | $hit | index($d)))
        | .name' <<<"$json"
}

status=0
run() {
    local dir="$1" swift="$2" tests filter log
    tests=$(select_tests "$dir")
    [ -z "$tests" ] && return 0
    filter="^($(paste -sd'|' - <<<"$tests"))\\."
    echo "test-changed: $dir -> $(paste -sd' ' - <<<"$tests")"
    log=$(mktemp)
    if ! (cd "$dir" && $swift test --filter "$filter") >"$log" 2>&1; then
        status=1
        grep -E 'error:|failed \(|signal code|^\s+- ' "$log" | grep -v ' 0 failures' | head -30
        grep -q 'signal code' "$log" &&
            echo "test-changed: a test bundle crashed; if HEAD passes on a clean checkout, the build cache is stale: rm -rf $dir/.build"
    fi
    awk '/Test Suite .(All|Selected) tests. (passed|failed)/ { getline; n += $2; f += $5 }
         /Test run with [0-9]+ tests/ { for (i = 1; i < NF; i++) if ($i == "with") n += $(i + 1) }
         END { printf "test-changed: %d tests, %d XCTest failures\n", n, f }' "$log"
    rm -f "$log"
}

run . "$PWD/scripts/swift.sh"
[ "$(uname)" = Darwin ] && run App swift
[ "$status" = 0 ] && echo "test-changed: OK" || echo "test-changed: FAILED"
exit "$status"
