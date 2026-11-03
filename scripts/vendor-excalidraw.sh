#!/usr/bin/env bash
# Rebuilds the Excalidraw editor ExcalidrawUI shows in its web view: Excalidraw, React and scripts/excalidraw/bridge.js
# bundled into App/Sources/Plugins/ExcalidrawUI/Resources/excalidraw/, with the fonts, so nothing loads from the
# network. The output is committed; run this only to change a version or the bridge.
set -euo pipefail
cd "$(dirname "$0")/.."

EXCALIDRAW=0.18.1
REACT=19.1.0
ESBUILD=0.25.5

out="App/Sources/Plugins/ExcalidrawUI/Resources/excalidraw"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp scripts/excalidraw/bridge.js "$work/"
(
  cd "$work"
  npm init -y >/dev/null
  npm install --silent --no-audit --no-fund \
    "@excalidraw/excalidraw@$EXCALIDRAW" "react@$REACT" "react-dom@$REACT" "esbuild@$ESBUILD"
  npx esbuild bridge.js --bundle --splitting --format=esm --minify --target=safari17 \
    --conditions=production --define:process.env.NODE_ENV='"production"' \
    --entry-names=loam-excalidraw --chunk-names='chunks/[name]-[hash]' --asset-names='assets/[name]-[hash]' \
    --loader:.woff2=file --loader:.png=file --loader:.svg=file --outdir=build
)

rm -rf "$out"
mkdir -p "$out"
cp -R "$work/build/." "$out/"
cp scripts/excalidraw/index.html "$out/"
# Every font but Xiaolai (12 MB of Chinese glyphs, fetched from Excalidraw's CDN when a drawing needs it).
mkdir -p "$out/fonts"
for font in "$work/node_modules/@excalidraw/excalidraw/dist/prod/fonts/"*; do
  [ "$(basename "$font")" = Xiaolai ] || cp -R "$font" "$out/fonts/"
done
{
  echo "Excalidraw $EXCALIDRAW (https://github.com/excalidraw/excalidraw), React and React DOM $REACT"
  echo "(https://github.com/facebook/react), bundled with their dependencies by scripts/vendor-excalidraw.sh."
  echo
  # The npm package ships no LICENSE file: the repository's, MIT.
  cat <<'MIT'
MIT License

Copyright (c) 2020 Excalidraw

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
MIT
  echo
  cat "$work/node_modules/react/LICENSE"
} > "$out/LICENSE"

du -sh "$out"
