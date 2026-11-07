# Projects

A project is a folder of the projects folder (`Projects/` by default) holding the project's note, named after it,
and its task notes. A task is a note with a `status` (its Kanban column) and maybe a `due`, holding whatever text it
needs. Nothing else: no project database, no hidden ids. The `Projects` plugin (logic: `projects` service,
`projects.*` commands) and `ProjectsUI` (the Projects page, the progress row, the day's project tasks) build it from
bricks Loam already has: collections (the Kanban), the editor and daily notes.

```
Projects/
  Projects.base                 ← the Projects page: the project notes, by status
  Website redesign/
    Website redesign.md         ← the project: status, due, what it is about, the Kanban of its tasks
    Write homepage copy.md      ← a task: status, due, and any text (notes, links, a checklist)
    Finalize navigation.md
```

```markdown
---
status: Active
due: 2026-11-19
---
A faster home page for the launch.

```base
name: Tasks
filters:
  and:
    - file.inFolder(this.file.folder)
    - file.basename != this.file.basename
    - file.ext == "md"
properties:
  status:
    type: select
    options: [To do, In progress, Done]
  due:
    type: date
views:
  - type: kanban
    name: Board
    groupBy: {property: status, direction: ASC}
    order: [file.name, due]
```
```

## What it is for

One person, many projects:

1. **Where do my projects stand?** The Projects page: grouped by status, each with where its tasks stand ("1 in
   progress · 3 to do"), its progress (Done tasks of all), its late tasks and its due date, red once passed.
2. **What is left on this one?** The project's note: what it is about, then the Kanban of its tasks. A card is a
   task note: its title, its due date, its checklist ("1/3").
3. **What do I do today?** The project tasks due that day (today, the late ones too) show above the daily note.

## Rules

- **A task's state is its `status`**, which is its column: dragging a card writes it. To do, In progress and Done by
  default; the board's settings rename or add columns. A status of Done, Completed or Finished
  (or French Fait, Terminé) counts as done; In progress, Doing, WIP (or En cours) as in progress.
- **A task is a note**: everything about it (notes, links, files, a checklist of sub-tasks) goes in its text. Its
  checklist's progress shows on its card.
- **Progress** of a project: its Done task notes of all. A task is late when it is not done and its `due` is past. A
  project is overdue when its own `due` is past and it is not done (status Done, or every task done).
- **Statuses of projects** are a select of the folder's collection: Active, Idea, Paused, Done.
- **Renaming a project**: renaming its note renames its folder, renaming its folder renames its note. The Kanban
  reads `this.file.folder`, so it needs no rewrite.
- **Loose notes**: a note directly in `Projects/` (an older layout, a note dropped there) is not a project; the
  Projects page offers "Tidy up", which moves each into a folder of its own (`projects.tidy`). An empty note made
  there moves into its own folder at once and becomes a project.
- **The folder's collection** (`Projects/Projects.base`, the project notes only: `file.folder == "Projects/" + file.basename`) is written the first time
  Projects or New project is used, never at launch; an existing one is left as the user made it. The folder is the
  plugin's `folder` setting.
- **Writes**: a new project note, the collection, an empty note created in the folder (it gets `status: Active` and
  the body of a project), a project's Kanban on request, and the moves of a rename.

## In the app

- **Projects** in the sidebar opens the folder as its collection. Its first
  view lists the projects by status; Done is folded; a row's menu changes the status. Two more views come with it:
  Board (projects dragged between statuses) and Table.
- **New project**: "+" beside a status (or "New project" under it) opens a name field in that group; Return writes the
  note with that status and its Kanban, opens it and puts the caret where its description goes. The page toolbar's "+"
  menu (New Project) and `projects.new-project` do the same with "Untitled".
- **New task**: "+" in a column of the project's Kanban; it names the task and writes the note in the project's
  folder with that column's status. A click on a card opens the task.
- **In a project note**: the collection's fields (Status, Due, and any field the user adds; a key only other notes of
  the folder have is not listed), then Progress ("2/6", the late tasks). A project note without its Kanban (an older
  one, a note moved into the folder) shows "Add task board" there instead.

## Commands

| Command | Does |
|---|---|
| `projects.list` | every project: path, title, status, due, overdue, tasks {done, total, inProgress, late}. Optional: `status` |
| `projects.due` | the open task notes due on a day (default today, with the late ones): path, title, project, status, due. Optional: `day` |
| `projects.new` | creates a project note (`title`, optional `status`, `due`) with its Kanban, and the folder's collection if missing. Writes |
| `projects.open` | (app) opens the projects page |
| `projects.new-project` | (app) creates an Active project (optional `title`) and opens it. Writes |

An agent adds a task by writing a note in `Projects/<project>/` with `status` and `due` in its frontmatter.

## Out of scope

Teams, assignees, comments, activity feeds, Gantt charts, time tracking. A project is one person's note.
