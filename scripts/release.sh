#!/usr/bin/env bash
# Builds a signed release of the app and its update feed (docs/UPDATES.md). Usage:
#
#   scripts/release.sh <version> [--beta] [--publish]
#
# Writes dist/Loam-<version>.zip and dist/feed/{stable,beta}.json: the zip is signed with the Ed25519 key at
# $LOAM_UPDATE_KEY (default ~/.config/loam/update-ed25519.key; `swift scripts/update-key.swift generate` makes one),
# whose public half App/Resources/update-public-key.txt is built into the app. A stable release goes to both
# channels, a beta (--beta) to the beta channel only.
#
# --publish uploads the zip as a GitHub release of $LOAM_RELEASES_REPO (default Azilone/loam-releases, public) and
# commits the feed files to its main branch, where installed apps and the install script read them.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

version="${1:?usage: scripts/release.sh <version> [--beta] [--publish]}"
shift
channel=stable
publish=0
for flag in "$@"; do
  case "$flag" in
    --beta) channel=beta ;;
    --publish) publish=1 ;;
    *) echo "unknown option $flag" >&2; exit 2 ;;
  esac
done
repo="${LOAM_RELEASES_REPO:-Azilone/loam-releases}"
key="${LOAM_UPDATE_KEY:-$HOME/.config/loam/update-ed25519.key}"
[ -f "$key" ] || { echo "no release key at $key: swift scripts/update-key.swift generate $key" >&2; exit 1; }
public_key="$(tr -d '[:space:]' < App/Resources/update-public-key.txt)"
[ "$(swift scripts/update-key.swift public "$key")" = "$public_key" ] \
  || { echo "$key does not match App/Resources/update-public-key.txt" >&2; exit 1; }

# Build number: the commit count, raised above every published build (the repository's history was restarted, and
# an app only takes a higher build as an update).
build="${LOAM_BUILD:-}"
if [ -z "$build" ]; then
  build="$(git rev-list --count HEAD)"
  for name in stable beta; do
    published="$(gh api "repos/$repo/contents/$name.json" -H "Accept: application/vnd.github.raw" 2>/dev/null \
      | python3 -c 'import json, sys; print(json.load(sys.stdin)["build"])' 2>/dev/null || echo 0)"
    [ "$published" -ge "$build" ] && build=$((published + 1))
  done
fi
LOAM_RELEASE=1 LOAM_VERSION="$version" LOAM_BUILD="$build" \
  LOAM_UPDATE_FEED="${LOAM_UPDATE_FEED:-https://raw.githubusercontent.com/$repo/main}" \
  ./scripts/build-app.sh release

mkdir -p dist/feed
zip="dist/Loam-$version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent App/build/Loam.app "$zip"
sha256="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
size="$(stat -f%z "$zip")"
signature="$(swift scripts/update-key.swift sign "$key" "$zip")"
swift scripts/update-key.swift verify "$public_key" "$zip" "$signature"
url="${LOAM_RELEASE_URL:-https://github.com/$repo/releases/download/v$version/Loam-$version.zip}"
notes="${LOAM_RELEASE_NOTES:-}"

feed() {
  python3 - "$@" <<'PY'
import json, sys
version, build, url, size, sha256, signature, notes, date = sys.argv[1:9]
print(json.dumps({"version": version, "build": int(build), "url": url, "size": int(size), "sha256": sha256,
                  "signature": signature, "minimumSystemVersion": "26.0", "notes": notes, "date": date}, indent=2))
PY
}
entry="$(feed "$version" "$build" "$url" "$size" "$sha256" "$signature" "$notes" "$(date +%Y-%m-%d)")"
channels=(beta)
[ "$channel" = stable ] && channels=(stable beta)

if [ "$publish" = 1 ]; then
  # The feed files live in the releases repository: start from what is published, so the other channel is kept.
  rm -rf dist/feed
  gh repo clone "$repo" dist/feed -- --depth 1 -q
fi
for name in "${channels[@]}"; do echo "$entry" > "dist/feed/$name.json"; done
echo "Release $version (build $build, $channel): $zip"
echo "Feed: ${channels[*]/%/.json} in dist/feed"

if [ "$publish" = 1 ]; then
  prerelease=()
  [ "$channel" = beta ] && prerelease=(--prerelease)
  gh release create "v$version" "$zip" --repo "$repo" --title "Loam $version" --notes "${notes:-Loam $version}" ${prerelease[@]+"${prerelease[@]}"}
  git -C dist/feed add "${channels[@]/%/.json}"
  git -C dist/feed commit -q -m "Loam $version ($channel)"
  git -C dist/feed push -q
  echo "Published v$version to $repo"
fi
