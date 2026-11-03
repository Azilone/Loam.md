# Tasks

A task is a GFM task-list line in any note. Nothing else: no task database, no hidden ids. The `Tasks` plugin reads
these lines across the vault (the `tasks` service and the `tasks.*` commands); `TasksUI` shows them in the app.

```markdown
---
project: Launch
---
## Tasks
- [ ] Ship the beta 📅 2026-10-20 #work ⏫
- [ ] Call Bob due:2026-10-22 !low
- [x] Write the plan ✅ 2026-10-17
```

## What counts as a task

- A list item whose text starts with `[ ]` (open) or `[x]` / `[X]` (done), then a space and some text. Any list
  marker (`-`, `*`, `+`, `1.`, `1)`) and any indentation, so nested tasks count.
- Not inside a fenced code block (```` ``` ```` or `~~~`), not in the YAML frontmatter.
- Other states (`[-]`, `[/]`) and an empty `- [ ]` are not tasks.

## Metadata on the line

Kept to two conventions people already write, so the line stays readable as plain text.

| Meaning | Write | Notes |
|---|---|---|
| Due date | `📅 2026-10-20` or `due:2026-10-20` | `YYYY-MM-DD` |
| High priority | `⏫` or `!high` | |
| Low priority | `🔽` or `!low` | anything else is normal |
| Done on | `✅ 2026-10-17` | written by `tasks.toggle` when it checks a task, removed when it unchecks it |
| Tags | `#work`, `#work/calls` | the note graph's tag rule; `#work` also matches `#work/calls` in filters |

The task's `text` is the line without the checkbox, the due date, the priority and the completion date. Tags stay in
it.

## In the editor

Typing `@` in a note opens Craft's "Days" menu (the `TasksUI` plugin's section of the `@` menu): `@tomorrow`,
`@fri`, `@next week`, `@in 3 days`, `@21oct`, `@21/10`, and French words such as `@demain`. Choosing a day writes `📅 YYYY-MM-DD` on the
line, replacing a due date already there. The editor draws each `📅`, `due:` and `✅` date as a pill ("Today",
"Tomorrow", "Wed, Oct 21"): blue, red when an open task is overdue, grey once done. The Markdown stays the line
above; clicking a pill selects its text, so `@` replaces it with another day and Delete removes it.

## Project

The note's frontmatter `project` property (a plain value, the first item of a list, or a `[[link]]` without its
brackets); without one, the note's folder (`""` at the vault root).

## Commands

| Command | Does |
|---|---|
| `tasks.list` | every task, sorted by due date (none last), priority (high first), path, line. Filters: `done`, `dueBefore`, `dueOn` (a date or `today`), `project`, `tag`, `path` (a note or folder), `text`, or `filter` as JSON |
| `tasks.toggle` | checks or unchecks one line. Arguments `path`, `line`, `text` (as `tasks.list` returned it): it refuses, writing nothing, when that line no longer holds that task, so a stale list never edits the wrong line. Writes |
| `tasks.add` | adds `- [ ] text` to a note, at the end of its `## Tasks` section (any heading level) if it has one, else at the end; creates the note if missing. Writes |
| `tasks.open` | (app) opens the task list in a new tab; `project` for `tasks:<project>` |
| `tasks.add-quick` | (app) opens the list with the add field focused; with `text`, adds it to today's daily note (or `Inbox.md` without daily notes). Writes |

```bash
loam --vault ~/Notes tasks.list done=false dueBefore=today
loam --vault ~/Notes tasks.toggle path=Work/Launch.md line=5 text="Ship the beta #work"
```
