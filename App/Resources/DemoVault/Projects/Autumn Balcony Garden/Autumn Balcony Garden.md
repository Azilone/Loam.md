---
status: Idea
---
A small balcony garden: cherry tomatoes, herbs, radishes. An idea for the spring.

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
