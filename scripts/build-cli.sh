#!/usr/bin/env bash
# Builds the `loam` command line, optimised, with its runtime next to it:
#   CLI/.build/release/loam
#   CLI/.build/release/libLoamRuntime.dylib   (.so on Linux)
# `loam` finds the library beside itself (rpath @loader_path, $ORIGIN on Linux): to install it, copy both files to one
# folder on the PATH. Stamped with the runtime build id, so it loads plugins built from the same sources
# (scripts/build-example-plugin.sh, later `loam plugin build`).
set -euo pipefail
cd "$(dirname "$0")/.."
trap './scripts/stamp-build-id.sh --restore' EXIT
echo "Runtime build id: $(./scripts/stamp-build-id.sh)"
./scripts/swift.sh build -c release --package-path CLI --product loam
echo "Built $PWD/CLI/.build/release/loam"
