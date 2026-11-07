#!/usr/bin/env python3
"""Prints the notes of the next release: the items of the first section of CHANGELOG.md (read on stdin) that has any.

CHANGELOG.md opens with `## Unreleased`, which the agents fill as they change what people see; before a stable release
that heading becomes the version (`## 0.1.2 - 2026-11-07`). Items are the `- ` lines and the lines that continue them.
"""
import sys

items, started = [], False
for line in sys.stdin.read().splitlines():
    if line.startswith("## "):
        if items:
            break
        started = True
        continue
    if not started or line.startswith("<!--"):
        continue
    if line.startswith("- "):
        items.append(line)
    elif items and line.startswith("  ") and line.strip():
        items[-1] += " " + line.strip()
print("\n".join(items))
