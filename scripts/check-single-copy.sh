#!/usr/bin/env bash
# Fails when two of the given images (executables, dylibs) define the same Swift type or protocol, or the same
# Objective-C class: the process would hold two copies of it, and a plugin would see one while the app uses the
# other (docs/PLUGIN-LOADING.md). Types the compiler emits per module for imported C and Objective-C declarations
# (`$sSo…`, `$sSC…`) are expected and ignored. Usage: check-single-copy.sh <image> <image> [...]
set -euo pipefail
[ "$#" -ge 2 ] || { echo "usage: $0 <image> <image> [...]" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for image in "$@"; do
  [ -f "$image" ] || { echo "not found: $image" >&2; exit 2; }
  # Nominal type descriptors (Mn), protocol descriptors (Mp) and Objective-C classes the image defines.
  nm -U "$image" | awk '{print $NF}' \
    | grep -E '(Mn|Mp)$|^_OBJC_CLASS_\$_' \
    | grep -vE '^_?\$s(So|SC)' \
    | sort -u > "$work/$(basename "$image").symbols" || true
done

sort "$work"/*.symbols | uniq -d > "$work/duplicates"
if [ -s "$work/duplicates" ]; then
  echo "error: these types are defined in more than one image:" >&2
  while read -r symbol; do
    owners="$(grep -lxF "$symbol" "$work"/*.symbols | xargs -n1 basename | sed 's/\.symbols$//' | paste -sd, -)"
    echo "  $(xcrun swift-demangle --simplified "$symbol" 2>/dev/null || echo "$symbol")  ($owners)" >&2
  done < <(head -20 "$work/duplicates")
  exit 1
fi
echo "One copy of every type across: $(for i in "$@"; do basename "$i"; done | paste -sd' ' -)"
