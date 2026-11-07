#!/usr/bin/env bash
# Builds the example plugin (Examples/HelloPlugin) and installs it into a vault:
#   <vault>/.loam/plugins/hello/plugin.json              what the app lists
#   <vault>/.loam/cache/plugins/hello/libHelloPlugin.dylib  its code (.so on Linux)
#
# Usage: build-example-plugin.sh [--no-build] <vault>
#
# The plugin is built against this checkout with the same compiler and the same stamped build id as `make app` and
# `make release` (scripts/stamp-build-id.sh), so the app built from the same sources accepts it. It is installed
# disabled: enable it with `loam --vault <vault> plugins.enable id=hello` or `"enabled": true` in .loam/config.json.
# --no-build installs the last build. Refuses an iCloud path. `loam plugin install Examples/HelloPlugin` does the same
# through the CLI (docs/PLUGIN-LOADING.md); this script stays for ExamplePluginTests and `make example-plugin`.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

build=1
vault=""
for arg in "$@"; do
  case "$arg" in
    --no-build) build=0 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "build-example-plugin: unknown option $arg" >&2; exit 2 ;;
    *) vault="$arg" ;;
  esac
done
[ -n "$vault" ] || { echo "usage: $0 [--no-build] <vault>" >&2; exit 2; }
case "$vault" in
  *"Mobile Documents"*|*"iCloud~md~obsidian"*)
    echo "build-example-plugin: refusing $vault: it looks like an iCloud vault; use a test folder" >&2; exit 1 ;;
esac
[ -d "$vault" ] || { echo "build-example-plugin: no folder at $vault" >&2; exit 1; }

package="Examples/HelloPlugin"
if [ "$(uname)" = Darwin ]; then ext=dylib; else ext=so; fi
library="libHelloPlugin.$ext"

if [ "$build" = 1 ]; then
  trap './scripts/stamp-build-id.sh --restore' EXIT
  echo "Runtime build id: $(./scripts/stamp-build-id.sh)"
  swift build -c release --package-path "$package" --product HelloPlugin
fi
bin="$(swift build -c release --package-path "$package" --show-bin-path)"
[ -f "$bin/$library" ] || { echo "build-example-plugin: $bin/$library not found; run without --no-build" >&2; exit 1; }

cache="$vault/.loam/cache/plugins/hello"
mkdir -p "$cache" "$vault/.loam/plugins/hello"
cp "$package/plugin.json" "$vault/.loam/plugins/hello/plugin.json"
rm -f "$cache/$library"
cp "$bin/$library" "$cache/$library"

if [ "$(uname)" = Darwin ]; then
  # The build leaves an rpath to its own build folder, which holds a second copy of the runtime. Removing it leaves
  # only the runtime the app (or `loam`) already loaded, matched by its install name, @rpath/libLoamRuntime.dylib.
  otool -l "$cache/$library" | awk '/LC_RPATH/ {getline; getline; print $2}' | while read -r rpath; do
    case "$rpath" in /*) install_name_tool -delete_rpath "$rpath" "$cache/$library" 2>/dev/null ;; esac
  done
  codesign --force --sign - "$cache/$library" >/dev/null 2>&1
fi
echo "Installed the example plugin \"hello\" in $vault (disabled until enabled in .loam/config.json)"
