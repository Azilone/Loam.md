#!/usr/bin/env bash
# Publishes the `loam` command line for Linux (amd64, arm64) and the one-line installer (scripts/install.sh) as a
# release of Azilone/loam-releases, the public repository agents download from. Needs Docker and gh.
#
#   scripts/release-cli.sh            builds both, then replaces the assets of the release `cli`
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
repo="${LOAM_RELEASES_REPO:-Azilone/loam-releases}"
build="$(cat VERSION 2>/dev/null || echo 0.1.0)-$(git rev-list --count HEAD)"
scripts/build-linux-cli.sh amd64
scripts/build-linux-cli.sh arm64
cp scripts/install.sh dist/install.sh
(cd dist && shasum -a 256 loam-linux-*.tar.gz install.sh > SHA256SUMS)
# One release with a fixed tag, `cli`, replaced in place: the installer's address never changes, and the app's own
# releases (v…) stay the repository's latest.
notes="The loam command line for Linux agents, build $build. Install: curl -fsSL https://github.com/$repo/releases/download/cli/install.sh | LOAM_CONNECT=loam-connect:… sh"
if gh release view cli -R "$repo" >/dev/null 2>&1; then
  gh release edit cli -R "$repo" --notes "$notes" --latest=false
  gh release upload cli -R "$repo" --clobber dist/loam-linux-amd64.tar.gz dist/loam-linux-arm64.tar.gz dist/install.sh dist/SHA256SUMS
else
  gh release create cli -R "$repo" --latest=false --title "Loam command line" --notes "$notes" \
    dist/loam-linux-amd64.tar.gz dist/loam-linux-arm64.tar.gz dist/install.sh dist/SHA256SUMS
fi
echo "Published build $build on $repo (release cli)"
