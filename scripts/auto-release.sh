#!/usr/bin/env bash
# Publishes a release once a push of the beta or prod branch has landed (docs/UPDATES.md). The pre-push hook
# (scripts/git-hooks/pre-push) starts it in the background; by hand:
#
#   scripts/auto-release.sh <remote> <beta|prod> <commit>
#
# beta publishes <next>-beta.N to the beta channel, prod publishes <next> to both channels, where <next> is the
# version the current beta series leads to, else the stable version with its patch raised. LOAM_NEXT_VERSION=0.2.0
# in the pushing shell picks the version instead. The release is built in its own worktree at that commit
# (~/Library/Caches/Loam/release-worktree), tagged v<version> in this repository, and announced by a notification.
set -euo pipefail
remote="${1:?usage: scripts/auto-release.sh <remote> <beta|prod> <commit>}"
branch="${2:?}"
sha="${3:?}"
case "$branch" in beta) channel=beta ;; prod) channel=stable ;; *) echo "unknown branch $branch" >&2; exit 2 ;; esac
releases="${LOAM_RELEASES_REPO:-Azilone/loam-releases}"
repo_dir="$(cd "$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
cache="$HOME/Library/Caches/Loam"
worktree="$cache/release-worktree"
mkdir -p "$cache"

notify() { osascript -e "display notification \"$1\" with title \"Loam release\"" >/dev/null 2>&1 || true; }
echo "== $(date '+%Y-%m-%d %H:%M:%S') $branch ${sha:0:7}"
trap 'notify "Release of $branch failed: see ~/Library/Logs/Loam/release.log"' ERR

# The push must land first: a rejected push publishes nothing.
for _ in $(seq 120); do
  [ "$(git -C "$repo_dir" ls-remote "$remote" "refs/heads/$branch" | cut -f1)" = "$sha" ] && break
  sleep 5
done
[ "$(git -C "$repo_dir" ls-remote "$remote" "refs/heads/$branch" | cut -f1)" = "$sha" ] \
  || { echo "$remote/$branch is not at $sha after 10 minutes: nothing published"; notify "Push of $branch did not land: nothing published"; exit 1; }

# One release at a time.
until mkdir "$cache/release.lock" 2>/dev/null; do sleep 10; done
trap 'rmdir "$cache/release.lock"' EXIT

feed() { gh api "repos/$releases/contents/$1.json" -H "Accept: application/vnd.github.raw"; }
version="${LOAM_NEXT_VERSION:-$(python3 - "$channel" "$(feed stable)" "$(feed beta)" <<'PY'
import json, sys
channel, stable, beta = sys.argv[1], json.loads(sys.argv[2])["version"], json.loads(sys.argv[3])["version"]
def parse(v):
    base, _, n = v.partition("-beta.")
    return tuple(int(p) for p in base.split(".")), int(n) if n else None
stable_base, _ = parse(stable)
beta_base, beta_n = parse(beta)
series = beta_base if beta_n is not None and beta_base > stable_base else None
base = series or stable_base[:2] + (stable_base[2] + 1,)
text = ".".join(map(str, base))
if channel == "beta":
    print(f"{text}-beta.{beta_n + 1 if series else 1}")
else:
    print(text)
PY
)}"
[ "$channel" = beta ] && [ -n "${LOAM_NEXT_VERSION:-}" ] && [[ "$version" != *-beta.* ]] && version="$version-beta.1"
echo "Version $version ($channel)"

# Notes: the top section of CHANGELOG.md at that commit, written for the people who use Loam (AGENTS.md, "Releasing
# an update"). No release goes out without one: the commit list is not something to show them.
notes="$(git -C "$repo_dir" show "$sha:CHANGELOG.md" 2>/dev/null | "$repo_dir/scripts/changelog-notes.py")" || true
if [ -z "$notes" ]; then
  echo "CHANGELOG.md at ${sha:0:7} has nothing to announce: nothing published"
  notify "Nothing published: CHANGELOG.md has no notes for this release"
  exit 1
fi

if [ -d "$worktree" ]; then
  git -C "$worktree" checkout -q -f --detach "$sha"
else
  git -C "$repo_dir" worktree add -q --detach "$worktree" "$sha"
fi
flags=(--publish)
[ "$channel" = beta ] && flags+=(--beta)
LOAM_RELEASE_NOTES="$notes" "$worktree/scripts/release.sh" "$version" "${flags[@]}"
git -C "$repo_dir" tag "v$version" "$sha"
git -C "$repo_dir" push -q --no-verify "$remote" "refs/tags/v$version"
echo "Published $version ($channel) from ${sha:0:7}"
notify "Loam $version published ($channel)"
