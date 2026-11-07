---
tags: [tech, how-to]
---
# Back Up Your Photos

A copy outside the computer, every week.

## The 3-2-1 method
- **3** copies of your data
- **2** different media
- **1** copy off-site

## Backup script

```bash
#!/usr/bin/env bash
# Copy the Pictures folder to the external drive, without deleting anything.
rsync -av --progress ~/Pictures/ "/Volumes/Backup/Photos/"
```

And in Python, to count the photos to copy:

```python
from pathlib import Path

photos = list(Path.home().glob("Pictures/**/*.jpg"))
print(f"{len(photos)} photos to back up")
```

## Reminder
- [ ] Run the backup this Sunday ⏫ 📅 2026-11-01 #tech
