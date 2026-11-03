#!/usr/bin/env bash
# The onboarding's pictures of the app (App/Sources/Plugins/IntroUI/Resources/Brand/Shots): Loam on the demo vault, in
# each look the look card offers and with each plugin set the plugins card offers. Run it again when the app's
# window, the demo vault or those choices change. Needs a debug build (agent-run.sh makes one).
#
# Usage: scripts/onboarding-shots.sh [--no-build]
set -euo pipefail
cd "$(dirname "$0")/.."
out="App/Sources/Plugins/IntroUI/Resources/Brand/Shots"
name="onboarding-shots"
ctl() { scripts/loam-ctl -i "$name" "$@" >/dev/null; }
tmp="$(mktemp -d)"
trap 'scripts/loam-ctl -i "$name" quit >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

# The demo vault, in a folder named as the user's first vault is.
cp -R App/Resources/DemoVault "$tmp/Loam"
scripts/agent-run.sh "$name" --vault "$tmp/Loam" --fresh --no-badge "$@" | tail -1
sleep 2
# 600 × 440, the window on the cards, at twice its size: the app's own layout at a window it can hold.
ctl window 1200 880
ctl open Home.md

optional=(meetings habit-tracker projects canvas excalidraw mindmap)
preset() {
    local off=" $1 "
    for id in "${optional[@]}"; do
        if [[ "$off" == *" $id "* ]]; then ctl run plugins.disable "id=$id"; else ctl run plugins.enable "id=$id"; fi
    done
    sleep 1
}
shot() {
    # The pointer over an empty spot of the tab bar, so nothing shows hovered.
    ctl hover 760,26
    sleep 1.2
    scripts/loam-ctl -i "$name" shot "$tmp/$1.png" --scale 1 >/dev/null
    # The card shows it at 600 × 440 points: 1200 × 880 pixels for Retina, as JPEG.
    sips -s format jpeg -s formatOptions 82 -z 880 1200 "$tmp/$1.png" --out "$out/$1.jpg" >/dev/null
    echo "$out/$1.jpg"
}

ctl run themes.use name=dither-green
preset ""; shot plugins-everything
preset "meetings habit-tracker canvas excalidraw mindmap"; shot plugins-tasks
preset "${optional[*]}"; shot plugins-writing
preset ""
for look in dither-green dither ink dracula; do
    ctl run themes.use "name=$look"
    shot "look-$look"
done
