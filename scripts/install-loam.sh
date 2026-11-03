#!/usr/bin/env bash
# Installs the `loam` command line on a Linux server or an agent's sandbox, from the archive
# scripts/build-linux-cli.sh makes (a path, or a URL the machine can download). No Swift toolchain needed; git,
# libcurl and libxml2 are (apt-get install -y git libcurl4 libxml2).
#
#   scripts/install-loam.sh <archive-path-or-url> [prefix]     prefix: ~/.local by default
#
# Then, for a vault the agent works in (see "Agents on other machines" in docs/GIT-SYNC.md):
#   export LOAM_VAULT_KEY=loam-key:…            # from sync.key.export on a Mac: a secret, kept out of files
#   mkdir -p ~/vault && loam --vault ~/vault sync.setup url=<repository> device=agent-name maxChanges=30
set -euo pipefail
source="${1:?usage: install-loam.sh <archive-path-or-url> [prefix]}"
prefix="${2:-$HOME/.local}"
command -v git >/dev/null || { echo "git is needed: apt-get install -y git libcurl4 libxml2" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
case "$source" in
  http://*|https://*) curl -fsSL "$source" -o "$work/loam.tar.gz" ;;
  *) cp "$source" "$work/loam.tar.gz" ;;
esac
tar -xzf "$work/loam.tar.gz" -C "$work"
folder="$(find "$work" -maxdepth 1 -type d -name 'loam-linux-*' | head -n 1)"
[ -n "$folder" ] || { echo "Not a Loam archive: $source" >&2; exit 1; }
mkdir -p "$prefix/share" "$prefix/bin"
rm -rf "$prefix/share/loam"
mv "$folder" "$prefix/share/loam"
ln -sf "$prefix/share/loam/loam" "$prefix/bin/loam"
if ! "$prefix/bin/loam" help >/dev/null 2>"$work/error"; then
  cat "$work/error" >&2
  echo "Swift's Foundation needs libcurl and libxml2: apt-get install -y libcurl4 libxml2 (dnf: libcurl libxml2)." >&2
  exit 1
fi
echo "Installed $prefix/bin/loam"
case ":$PATH:" in *":$prefix/bin:"*) ;; *) echo "Add it to the PATH: export PATH=\"$prefix/bin:\$PATH\"" ;; esac
