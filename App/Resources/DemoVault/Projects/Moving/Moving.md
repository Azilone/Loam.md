---
status: Active
due: 2026-12-01
---
Leave the old apartment on November 30, move in on December 1. The lease is handled with the landlord, see [[Meetings/2026-10-23 1930 Landlord Call/Summary|the October 23 call]].

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
