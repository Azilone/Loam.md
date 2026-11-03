#!/usr/bin/env bash
# Creates a demo vault to try the app on: folders, linked notes, an image attachment, today's daily note,
# frontmatter, tasks, a table and a code block.
#
# Usage: make-test-vault.sh [--force] [path]     (default path: ~/TestVault)
#
# Refuses an iCloud (Obsidian) path, so it can never touch a real vault, and refuses a folder that is not empty
# unless --force is given. It never deletes anything: with --force, files that already exist are left as they are.
set -euo pipefail

force=0
target=""
for arg in "$@"; do
    case "$arg" in
        --force) force=1 ;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "make-test-vault: unknown option $arg" >&2; exit 2 ;;
        *)
            if [[ -n "$target" ]]; then echo "make-test-vault: only one path, please" >&2; exit 2; fi
            target="$arg" ;;
    esac
done
target="${target:-$HOME/TestVault}"
target="${target/#\~/$HOME}"

refuse_icloud() {
    case "$1" in
        *"Mobile Documents"*|*"iCloud~md~obsidian"*)
            echo "make-test-vault: refusing $1: it looks like an iCloud vault; use a test folder such as ~/TestVault" >&2
            exit 1 ;;
    esac
}
refuse_icloud "$target"
# The same check on the real path, in case a symlink leads into iCloud.
parent="$(dirname "$target")"
while [[ ! -d "$parent" ]]; do parent="$(dirname "$parent")"; done
refuse_icloud "$(cd "$parent" && pwd -P)"
if [[ -e "$target" ]]; then
    if [[ ! -d "$target" ]]; then echo "make-test-vault: $target exists and is not a folder" >&2; exit 1; fi
    refuse_icloud "$(cd "$target" && pwd -P)"
    if [[ -n "$(ls -A "$target")" && $force -eq 0 ]]; then
        echo "make-test-vault: $target is not empty; pass --force to add the demo notes (existing files are kept)" >&2
        exit 1
    fi
fi

mkdir -p "$target"
cd "$target"
created=0
skipped=0

# note <path>: writes stdin to <path> unless it exists.
note() {
    if [[ -e "$1" ]]; then
        skipped=$((skipped + 1))
        cat > /dev/null
        return
    fi
    mkdir -p "$(dirname "$1")"
    cat > "$1"
    created=$((created + 1))
}

today="$(date +%Y-%m-%d)"

note "Welcome.md" <<EOF
---
tags: [demo]
created: $today
---
# Welcome

A demo vault made by \`scripts/make-test-vault.sh\`. Every note is plain Markdown.

- Projects: [Website redesign](Projects/Website%20redesign.md) and [Reading list](Projects/Reading%20list.md)
- Health: [Running](Areas/Health/Running.md)
- Today: [$today](Daily/$today.md)

## Try

- [ ] Open a note with Cmd+O
- [ ] Run a command with Cmd+P
- [ ] Drag a note from the Files panel to the edge of a pane to split it
- [x] Open this vault
EOF

note "Projects/Website redesign.md" <<'EOF'
---
status: active
tags: [project, web]
due: 2026-12-01
---
# Website redesign

Goal: a faster home page. Related: [Reading list](Reading%20list.md), and stay fit with [Running](../Areas/Health/Running.md).

![Site map](../Attachments/sitemap.png)

## Tasks

- [x] Audit the current pages
- [ ] Draft the new navigation
- [ ] Measure the load time

## Pages

| Page | Owner | Status |
|---|---|---|
| Home | Kim | in progress |
| Blog | Sam | todo |
| About | Kim | done |

## Snippet

```swift
let pages = ["Home", "Blog", "About"]
for page in pages where page != "About" {
    print("To do: \(page)")
}
```
EOF

note "Projects/Projects.base" <<'EOF'
filters:
  and:
    - file.inFolder("Projects")
    - file.ext == "md"
properties:
  status:
    type: select
    options: [To do, In progress, Done]
views:
  - type: kanban
    name: Board
    groupBy: {property: status, direction: ASC}
    order: [file.name, status, due]
  - type: table
    name: Table
    order: [file.name, status, due]
  - type: cards
    name: Gallery
    order: [file.name, status]
EOF

note "Projects/Reading list.md" <<'EOF'
---
tags: [list]
---
# Reading list

1. *Make It Stick*, on learning
2. *Shape Up*, on running projects; see [Website redesign](Website%20redesign.md)
3. **The Pragmatic Programmer**

> Read a little every day.
EOF

note "Areas/Health/Running.md" <<'EOF'
---
tags: [health]
goal: 10 km under 55 min
---
# Running

Three runs a week. Back to [Welcome](../../Welcome.md).

| Day | Distance | Time |
|---|---|---|
| Monday | 5 km | 28:40 |
| Wednesday | 6 km | 34:10 |
| Saturday | 8 km | 46:05 |

- [ ] Buy new shoes
- [x] Sign up for the October race
EOF

note "Daily/$today.md" <<EOF
---
tags: [daily]
---
# $today

- Worked on [Website redesign](../Projects/Website%20redesign.md)
- Ran 5 km, see [Running](../Areas/Health/Running.md)

## Tasks

- [ ] Reply to the design review
- [x] Water the plants
EOF

# A mindmap note (the format of MindmapUI), shown live on the demo board.
note "Maps/Trip ideas.md" <<'EOF'
---
mindmap-plugin: basic
---

# Trip ideas

- Where
	- Lisbon
	- Porto
- When
	- May
- Budget
EOF

# A board (JSON Canvas, docs/CANVAS.md): notes as cards, a text card, a link and a group, joined by arrows.
note "Boards/Demo.canvas" <<'EOF'
{
	"nodes":[
		{"id":"group1","type":"group","label":"This week","x":-60,"y":-80,"width":1420,"height":620},
		{"id":"site","type":"file","file":"Projects/Website redesign.md","x":0,"y":0,"width":400,"height":420},
		{"id":"run","type":"file","file":"Areas/Health/Running.md","x":520,"y":0,"width":360,"height":300,"color":"4"},
		{"id":"idea","type":"text","text":"## Idea\nRun to the office **twice a week**","x":1000,"y":0,"width":300,"height":120,"color":"3"},
		{"id":"spec","type":"link","url":"https://jsoncanvas.org/spec/1.0/","x":1000,"y":220,"width":300,"height":160},
		{"id":"read","type":"file","file":"Projects/Reading list.md","x":0,"y":700,"width":400,"height":360},
		{"id":"map","type":"file","file":"Maps/Trip ideas.md","x":520,"y":700,"width":560,"height":360,"color":"5"},
		{"id":"big","type":"file","file":"Boards/Big.canvas","x":1200,"y":700,"width":360,"height":300}
	],
	"edges":[
		{"id":"e1","fromNode":"site","fromSide":"right","toNode":"run","toSide":"left","label":"after work"},
		{"id":"e2","fromNode":"run","fromSide":"right","toNode":"idea","toSide":"left"},
		{"id":"e3","fromNode":"site","fromSide":"bottom","toNode":"read","toSide":"top","toEnd":"none"},
		{"id":"e4","fromNode":"read","fromSide":"right","toNode":"map","toSide":"left","label":"plan"}
	]
}
EOF

# A large board, to check that moving and zooming stay smooth: 1,000 cards and 1,000 arrows.
if [[ -e "Boards/Big.canvas" ]]; then
    skipped=$((skipped + 1))
else
    mkdir -p Boards
    {
        printf '{\n\t"nodes":[\n'
        for i in $(seq 0 999); do
            color=$(( i % 7 )); sep=","; [[ $i -eq 999 ]] && sep=""
            c=""; [[ $color -ne 0 ]] && c=",\"color\":\"$color\""
            printf '\t\t{"id":"n%d","type":"text","text":"## Card %d\\nSome text on card %d","x":%d,"y":%d,"width":260,"height":120%s}%s\n' \
                "$i" "$i" "$i" $(( (i % 40) * 320 )) $(( (i / 40) * 220 )) "$c" "$sep"
        done
        printf '\t],\n\t"edges":[\n'
        for i in $(seq 0 999); do
            sep=","; [[ $i -eq 999 ]] && sep=""
            printf '\t\t{"id":"e%d","fromNode":"n%d","toNode":"n%d"}%s\n' "$i" "$i" $(( (i + 1) % 1000 )) "$sep"
        done
        printf '\t]\n}\n'
    } > "Boards/Big.canvas"
    created=$((created + 1))
fi

# A 4x4 PNG, so the image link above points to a real file.
if [[ -e "Attachments/sitemap.png" ]]; then
    skipped=$((skipped + 1))
else
    mkdir -p Attachments
    base64 --decode > "Attachments/sitemap.png" <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR42mPQqDgBRwzEcQA/UhaBD7/eiwAAAABJRU5ErkJggg==
EOF
    created=$((created + 1))
fi

echo "Test vault at $(pwd -P): $created files created, $skipped already there."
