#!/bin/bash
# Compiles BorderBeamKit's Metal shader into the default.metallib the app ships, so building Loam does not need
# Xcode's Metal Toolchain. Run it after changing BeamShaders.metal (needs `xcodebuild -downloadComponent MetalToolchain`).
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)/App/Sources/BorderBeamKit"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
xcrun -sdk macosx metal -c -target air64-apple-macos26.0 -fmetal-math-mode=fast \
    "$kit/BeamShaders.metal" -o "$tmp/BeamShaders.air"
xcrun -sdk macosx metallib "$tmp/BeamShaders.air" -o "$kit/Resources/default.metallib"
echo "$kit/Resources/default.metallib"
