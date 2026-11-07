#!/bin/bash
# Installs what Loam's plugins run: Homebrew when it is missing, then git, ffmpeg and webp (cwebp) from it. swift comes
# with Apple's developer tools (Command Line Tools), which are asked for when they are missing. Loam opens this file in
# Terminal from Settings > Plugins > Dependencies; Homebrew's installer asks for your password.
set -u

say() { printf '\n==> %s\n' "$*"; }

brew_path() {
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then echo "$candidate"; return 0; fi
  done
  return 1
}

finish() {
  printf '\nPress Return to close this window.'
  read -r _
  exit "$1"
}

say "Homebrew"
BREW="$(brew_path || true)"
if [ -z "$BREW" ]; then
  say "Installing Homebrew"
  if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
    echo "Homebrew could not be installed. Nothing else was changed."
    finish 1
  fi
  BREW="$(brew_path || true)"
  if [ -z "$BREW" ]; then
    echo "Homebrew was installed, but not found in /opt/homebrew or /usr/local."
    finish 1
  fi
fi
echo "Found $BREW"

say "Apple developer tools (swift)"
if xcode-select -p >/dev/null 2>&1; then
  echo "Installed."
else
  echo "Not installed: Apple's installer opens now. Run this file again once it has finished."
  xcode-select --install >/dev/null 2>&1
fi

say "git, ffmpeg and webp"
"$BREW" install git ffmpeg webp

say "Check"
prefix="$("$BREW" --prefix)"
status=0
for tool in git ffmpeg cwebp; do
  if [ -x "$prefix/bin/$tool" ]; then
    echo "  ok       $tool"
  else
    echo "  missing  $tool"
    status=1
  fi
done
if xcode-select -p >/dev/null 2>&1; then
  echo "  ok       swift"
else
  echo "  missing  swift"
  status=1
fi
if [ "$status" -eq 0 ]; then
  echo "All set. Back in Loam, press Check again."
fi
finish "$status"
