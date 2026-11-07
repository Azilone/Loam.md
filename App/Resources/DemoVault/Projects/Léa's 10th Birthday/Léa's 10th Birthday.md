---
status: Active
due: 2026-12-12
---
Léa's 10th birthday, Saturday, December 12 at 7 pm. Neighbourhood community hall, 80 guests, €1,200 budget.

Decisions: [[Meetings/2026-10-27 1000 Birthday Planning/Summary|October 27 check-in]].

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
