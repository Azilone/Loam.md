#!/usr/bin/env bash
# The fast loop: rebuilds the Swift code and swaps the executable and the two runtime libraries into the existing debug
# bundle App/build/Loam.app, then signs them again. A few seconds on top of the compile, instead of build-app.sh's
# packaging (CLI build, SDK snapshot, plist, every signature).
#
# Exits 3 when the bundle has to be rebuilt in full (build-app.sh debug): no bundle yet, or a resource, the CLI or the
# plugin SDK changed since it was made. Any other failure is the compile's own.
set -euo pipefail
[ -n "${LOAM_BUILD_LOCKED:-}" ] || LOAM_LOCK_LANE=app exec "$(dirname "$0")/build-lock.sh" "$0" "$@"
cd "$(dirname "$0")/.."
root="$PWD"
app="$root/App/build/Loam.app"

[ -f "$app/Contents/Helpers/loam" ] && [ -f "$app/Contents/Info.plist" ] || exit 3
stale="$(find App/Resources CLI Sources/LoamCLI -path '*/.build' -prune -o -type f -newer "$app/Contents/Info.plist" -print -quit 2>/dev/null || true)"
[ -z "$stale" ] || { echo "dev-refresh: $stale changed, full bundle build" >&2; exit 3; }

cd App
swift build -c debug --package-path Executable --product Loam
bin="$(swift build -c debug --package-path Executable --show-bin-path)"
libraries=(libLoamRuntime.dylib libLoamUIRuntime.dylib)

rm -f "$app/Contents/MacOS/Loam"
cp "$bin/Loam" "$app/Contents/MacOS/Loam"
for library in "${libraries[@]}"; do cp "$bin/$library" "$app/Contents/Frameworks/$library"; done
for resources in "$bin"/*.bundle; do [ -d "$resources" ] && cp -R "$resources" "$app/Contents/Resources/"; done

delete_absolute_rpaths() {
  otool -l "$1" | awk '/LC_RPATH/ {getline; getline; print $2}' | while read -r rpath; do
    case "$rpath" in /*) install_name_tool -delete_rpath "$rpath" "$1" 2>/dev/null ;; esac
  done
}
delete_absolute_rpaths "$app/Contents/MacOS/Loam"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Loam" 2>/dev/null || true
for library in "${libraries[@]}"; do delete_absolute_rpaths "$app/Contents/Frameworks/$library"; done

identity="${LOAM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
identity="${identity:--}"
for library in "${libraries[@]}"; do codesign --force --sign "$identity" "$app/Contents/Frameworks/$library" >/dev/null 2>&1; done
codesign --force --sign "$identity" --entitlements Loam.entitlements "$app" >/dev/null 2>&1
codesign --verify --strict "$app"
echo "Refreshed $app"
