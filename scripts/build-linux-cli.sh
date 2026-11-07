#!/usr/bin/env bash
# Builds the `loam` command line for Linux in a Swift container, as a folder that runs on a server or an agent's
# sandbox without a Swift toolchain: the binary, Loam's runtime library and the Swift libraries it needs, found next
# to it (rpath $ORIGIN/lib). Needs Docker (OrbStack, Docker Desktop).
#
#   scripts/build-linux-cli.sh [arch]     arch: amd64 (default) or arm64
#
# Writes dist/loam-linux-<arch>.tar.gz. Install it on the machine with scripts/install-loam.sh.
set -euo pipefail
arch="${1:-amd64}"
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/dist"
docker run --rm --platform "linux/$arch" -v "$root:/src" -w /src swift:6.0 bash -c '
  set -e
  flags=(-c release --package-path CLI --scratch-path /tmp/loam-build -Xlinker -rpath -Xlinker "\$ORIGIN/lib")
  swift build "${flags[@]}" --product loam
  bin="$(swift build "${flags[@]}" --show-bin-path)"
  out=/tmp/loam-linux-'"$arch"'
  rm -rf "$out" && mkdir -p "$out/lib"
  cp "$bin/loam" "$out/loam"
  cp "$bin"/*.so "$out/lib/" 2>/dev/null || true
  # The Swift libraries the binary and Loam s own library load, from the toolchain.
  for library in $(ldd "$out/loam" "$out"/lib/*.so | awk "/swift|libFoundation|libdispatch|libBlocksRuntime|lib_/ {print \$3}" | sort -u); do
    cp -n "$library" "$out/lib/"
  done
  tar -czf /src/dist/loam-linux-'"$arch"'.tar.gz -C /tmp "loam-linux-'"$arch"'"
'
echo "Built $root/dist/loam-linux-$arch.tar.gz"
