#!/usr/bin/env bash
# Keeps compiled plugins working across releases. PluginKit and PluginKitUI are built with library evolution, so a
# plugin keeps running as long as they only gain API (docs/PLUGIN-LOADING.md, "Plugin SDK version"). This compares
# their ABI with the baseline in api/ and fails when:
#   - an API was removed, renamed or changed (a protocol requirement without a default, a stored property of a frozen
#     type…) and the major version of PluginSDKVersion.current was not bumped: plugins would crash;
#   - an API was added and the version was not bumped: plugins using it would not be refused by older apps.
# After a deliberate change, bump PluginSDKVersion.current (Sources/PluginKit/PluginSDKVersion.swift) and record the
# new baseline: scripts/check-plugin-api.sh --update. macOS only (library evolution is not used on Linux).
#
# Usage: check-plugin-api.sh [--update]
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

if [ "$(uname)" != Darwin ]; then
  echo "check-plugin-api: skipped (the plugin SDK is only ABI-stable on Apple platforms)"
  exit 0
fi

update=0
[ "${1:-}" = "--update" ] && update=1

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
digester="$(xcrun --find swift-api-digester)"
sdk="$(xcrun --show-sdk-path)"
arch="$(uname -m)"

version="$(sed -nE 's/.*static var current: PluginSDKVersion \{ PluginSDKVersion\(major: ([0-9]+), minor: ([0-9]+)\) \}.*/\1.\2/p' \
  Sources/PluginKit/PluginSDKVersion.swift)"
[ -n "$version" ] || { echo "check-plugin-api: cannot read PluginSDKVersion.current" >&2; exit 2; }

# Release builds: a debug build has testing enabled, which exposes internal declarations as if they were public.
swift build -c release --target PluginKit >/dev/null
(cd App && swift build -c release --target PluginKitUI >/dev/null)
kit_modules="$(swift build -c release --show-bin-path)"
ui_modules="$(cd App && swift build -c release --show-bin-path)"

dump() { # module, modules folder, deployment target, output
  "$digester" -dump-sdk -abi -module "$1" -I "$2" -sdk "$sdk" -target "$arch-apple-macosx$3" -o "$4"
}
dump PluginKit "$kit_modules" 13.0 "$work/PluginKit.json"
dump PluginKitUI "$ui_modules" 26.0 "$work/PluginKitUI.json"

if [ "$update" = 1 ]; then
  mkdir -p api
  for module in PluginKit PluginKitUI; do gzip -9n < "$work/$module.json" > "api/$module.abi.json.gz"; done
  echo "$version" > api/version
  echo "check-plugin-api: recorded the plugin SDK $version baseline in api/"
  exit 0
fi

[ -f api/version ] || { echo "check-plugin-api: no baseline; record one with $0 --update" >&2; exit 1; }
baseline="$(cat api/version)"
major() { echo "${1%%.*}"; }

added=0
broken=0
for module in PluginKit PluginKitUI; do
  gunzip < "api/$module.abi.json.gz" > "$work/$module.baseline.json"
  "$digester" -diagnose-sdk -abi -input-paths "$work/$module.baseline.json" -input-paths "$work/$module.json" \
    > "$work/$module.diff" 2>&1 || true
  # Section titles and blank lines say nothing; "a new API" is an addition; anything else breaks plugins.
  grep -vE '^/\* .* \*/$|^\s*$' "$work/$module.diff" > "$work/$module.changes" || true
  if grep -q "is a new API without '@available'" "$work/$module.changes"; then added=1; fi
  if grep -v "is a new API without '@available'" "$work/$module.changes" > "$work/$module.breaking"; then
    broken=1
    echo "check-plugin-api: $module changes in a way that breaks compiled plugins:"
    sed 's/^/  /' "$work/$module.breaking"
  fi
done

if [ "$broken" = 1 ] && [ "$(major "$version")" = "$(major "$baseline")" ]; then
  echo "check-plugin-api: plugins built for plugin SDK $baseline would crash. Add the new API next to the old one" >&2
  echo "instead; if the break is really needed, bump the major version of PluginSDKVersion.current (every plugin" >&2
  echo "then needs a rebuild) and run $0 --update." >&2
  exit 1
fi
if [ "$added" = 1 ] && [ "$version" = "$baseline" ]; then
  echo "check-plugin-api: the plugin SDK gained API:" >&2
  cat "$work"/*.changes | grep "is a new API" | sed 's/ is a new API without .*//; s/^/  /' >&2
  echo "Bump the minor version of PluginSDKVersion.current (Sources/PluginKit/PluginSDKVersion.swift, now $version)" >&2
  echo "and run $0 --update." >&2
  exit 1
fi
if [ "$added" = 1 ] || [ "$broken" = 1 ] || [ "$version" != "$baseline" ]; then
  echo "check-plugin-api: the baseline in api/ is plugin SDK $baseline, the SDK is $version: run $0 --update." >&2
  exit 1
fi
echo "check-plugin-api: plugin SDK $version unchanged"
