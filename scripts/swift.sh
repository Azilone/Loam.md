#!/usr/bin/env bash
# Runs `swift <args>` here when Swift is installed, otherwise in a throwaway Swift container
# (podman or docker), so the same command works on a Mac, on Linux and on a bare server.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v swift >/dev/null 2>&1; then
  exec swift "$@"
fi

runtime="$(command -v podman || command -v docker || true)"
if [ -z "$runtime" ]; then
  echo "Swift is not installed, and neither podman nor docker is available." >&2
  exit 1
fi
# Mounted under the folder's own name: CLI/ and App/ refer to the root package by that identity (loam).
exec "$runtime" run --rm -v "$PWD":/loam:Z -w /loam docker.io/library/swift:6.0 swift "$@"
