#!/bin/sh
# Loam for an agent's machine (Linux): installs the `loam` command line and, given a connect code, joins the vault.
#
#   curl -fsSL https://github.com/Azilone/loam-releases/releases/download/cli/install.sh | LOAM_CONNECT=loam-connect:… sh
#
# The code comes from Loam on a Mac: Settings > Sync > Connect an agent. Keep it as a secret of the agent's
# environment (LOAM_CONNECT): it is the agent's access to the vault. The vault lands in $LOAM_VAULT (~/vault).
# Afterwards: `loam --vault ~/vault sync.now` after each task, or `loam --vault ~/vault sync.watch` as a service.
set -eu
release="${LOAM_RELEASE_URL:-https://github.com/Azilone/loam-releases/releases/download/cli}"
prefix="${LOAM_PREFIX:-$HOME/.local}"
vault="${LOAM_VAULT:-$HOME/vault}"

case "$(uname -s)" in Linux) ;; *) echo "This installer is for Linux. On a Mac, install the Loam app." >&2; exit 1 ;; esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "No Loam build for $(uname -m)." >&2; exit 1 ;;
esac

missing=""
for tool in git ssh curl tar; do command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"; done
if [ -n "$missing" ] || ! ldconfig -p 2>/dev/null | grep -q libcurl.so.4; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo_="" ; [ "$(id -u)" -eq 0 ] || sudo_="sudo"
    $sudo_ apt-get update -qq >/dev/null
    $sudo_ apt-get install -y -qq git openssh-client curl ca-certificates libcurl4 libxml2 >/dev/null
  else
    echo "Install git, ssh, curl, libcurl and libxml2, then run this again." >&2; exit 1
  fi
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL "$release/loam-linux-$arch.tar.gz" -o "$work/loam.tar.gz"
tar -xzf "$work/loam.tar.gz" -C "$work"
mkdir -p "$prefix/share" "$prefix/bin"
rm -rf "$prefix/share/loam"
mv "$work/loam-linux-$arch" "$prefix/share/loam"
ln -sf "$prefix/share/loam/loam" "$prefix/bin/loam"
"$prefix/bin/loam" help >/dev/null
echo "Installed $prefix/bin/loam"

git config --global user.name >/dev/null 2>&1 || git config --global user.name "Loam agent"
git config --global user.email >/dev/null 2>&1 || git config --global user.email "agent@loam.invalid"

if [ -n "${LOAM_CONNECT:-}" ]; then
  mkdir -p "$vault"
  "$prefix/bin/loam" --vault "$vault" sync.join
  echo "The vault is in $vault. After each task: loam --vault $vault sync.now"
else
  echo "To join a vault: LOAM_CONNECT=loam-connect:… $prefix/bin/loam --vault ~/vault sync.join"
fi
case ":$PATH:" in *":$prefix/bin:"*) ;; *) echo "Add it to the PATH: export PATH=\"$prefix/bin:\$PATH\"" ;; esac
