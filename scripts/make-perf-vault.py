#!/usr/bin/env python3
"""Generates a large, Obsidian-like vault for performance tests: "a whole life" in Markdown.

Usage: make-perf-vault.py [--notes N] [--attachments-gb G] [--seed S] [--force] PATH

Defaults give a ~2 GB vault: 20,000 notes (~40 MB of text) in nested folders, ten years of daily notes, wikilinks,
tags, frontmatter, tasks, a few very long notes, an `.obsidian/` folder, and attachments (images, PDFs, audio). The
attachments are sparse files: their size is real for the file system walk, they take no disk space, read as zeros.

Deterministic for a given seed. Refuses an iCloud path and a non-empty folder unless --force.
"""
import argparse
import datetime
import os
import random
import sys

WORDS = (
    "the of and to in is for on with as at by from that this be are was it or an not but have can will more "
    "projet réunion idée lecture voyage famille santé sport budget travail code design note livre film musique "
    "café matin soir semaine objectif bilan priorité client équipe produit version bug feature recherche apprendre "
    "écrire penser marcher dormir manger appeler envoyer finir commencer revoir planifier ranger acheter payer"
).split()
TAGS = ["personal", "work", "idea", "book", "health", "finance", "travel", "family", "project/loam", "project/house",
        "learning/swift", "learning/music", "meeting", "journal", "recipe", "review"]
FOLDERS = ["Journal", "Projects", "Projects/Loam", "Projects/House", "Projects/Archive/2019", "Projects/Archive/2021",
           "Areas/Health", "Areas/Finance", "Areas/Family", "Resources/Books", "Resources/Articles",
           "Resources/Recipes", "Resources/Courses/Swift", "Meetings", "People", "Inbox", "Zettelkasten",
           "Zettelkasten/Permanent", "Zettelkasten/Literature", "Travel/Japan", "Travel/Italy"]
ATTACHMENT_KINDS = [("png", 0.55, 400_000, 4_000_000), ("jpg", 0.25, 1_000_000, 6_000_000),
                    ("pdf", 0.15, 200_000, 12_000_000), ("m4a", 0.05, 2_000_000, 30_000_000)]


def sentence(rng, n=None):
    n = n or rng.randint(6, 22)
    s = " ".join(rng.choice(WORDS) for _ in range(n))
    return s[0].upper() + s[1:] + "."


def paragraph(rng, titles, attachments):
    parts = []
    for _ in range(rng.randint(2, 6)):
        s = sentence(rng)
        r = rng.random()
        if r < 0.25 and titles:
            s = s[:-1] + f" [[{rng.choice(titles)}]]."
        elif r < 0.32:
            s = s[:-1] + f" #{rng.choice(TAGS)}."
        elif r < 0.35 and attachments:
            s += f"\n\n![[{rng.choice(attachments)}]]\n"
        parts.append(s)
    return " ".join(parts)


def note_body(rng, title, titles, attachments, size_factor=1):
    lines = []
    if rng.random() < 0.7:
        created = datetime.date(2015, 1, 1) + datetime.timedelta(days=rng.randint(0, 3900))
        lines += ["---", f"created: {created.isoformat()}", f"tags: [{', '.join(rng.sample(TAGS, rng.randint(1, 3)))}]"]
        if rng.random() < 0.3:
            lines.append(f"status: {rng.choice(['todo', 'doing', 'done', 'someday'])}")
        if rng.random() < 0.2:
            lines.append(f"rating: {rng.randint(1, 5)}")
        lines.append("---")
    lines += [f"# {title}", ""]
    for _ in range(rng.randint(2, 10) * size_factor):
        r = rng.random()
        if r < 0.15:
            lines.append(f"## {sentence(rng, 3)[:-1]}")
        elif r < 0.30:
            for _ in range(rng.randint(2, 6)):
                box = rng.choice(["- [ ] ", "- [x] ", "- "])
                due = f" 📅 {2026}-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}" if rng.random() < 0.2 else ""
                lines.append(box + sentence(rng, rng.randint(3, 9))[:-1] + due)
        elif r < 0.34:
            lines += ["| A | B | C |", "| --- | --- | --- |"]
            lines += [f"| {rng.choice(WORDS)} | {rng.randint(0, 999)} | {rng.choice(WORDS)} |" for _ in range(5)]
        elif r < 0.37:
            lines += ["```swift", "let x = 42", "print(x)", "```"]
        else:
            lines.append(paragraph(rng, titles, attachments))
        lines.append("")
    return "\n".join(lines) + "\n"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("path")
    p.add_argument("--notes", type=int, default=20_000)
    p.add_argument("--attachments-gb", type=float, default=1.9)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--force", action="store_true")
    a = p.parse_args()

    root = os.path.abspath(os.path.expanduser(a.path))
    if "Mobile Documents" in root or "iCloud~md~obsidian" in root:
        sys.exit(f"make-perf-vault: refusing {root}: looks like an iCloud vault")
    if os.path.isdir(root) and os.listdir(root) and not a.force:
        sys.exit(f"make-perf-vault: {root} is not empty (use --force)")
    rng = random.Random(a.seed)

    # Attachments first, so notes can embed them.
    attachments, total = [], 0
    budget = int(a.attachments_gb * 1024 ** 3)
    os.makedirs(f"{root}/Attachments", exist_ok=True)
    while total < budget:
        r, acc = rng.random(), 0.0
        for ext, share, lo, hi in ATTACHMENT_KINDS:
            acc += share
            if r <= acc:
                break
        size = rng.randint(lo, hi)
        name = f"Pasted image {len(attachments):05d}.{ext}" if ext in ("png", "jpg") else f"file-{len(attachments):05d}.{ext}"
        with open(f"{root}/Attachments/{name}", "wb") as f:
            f.truncate(size)
        attachments.append(name)
        total += size

    # Daily notes: ten years, most days.
    titles, paths = [], []
    day = datetime.date(2016, 1, 1)
    while day <= datetime.date(2026, 10, 22) and len(paths) < a.notes // 2:
        if rng.random() < 0.8:
            titles.append(day.isoformat())
            paths.append(f"Journal/{day.year}/{day.month:02d}/{day.isoformat()}.md")
        day += datetime.timedelta(days=1)
    while len(paths) < a.notes:
        t = sentence(rng, rng.randint(2, 5))[:-1].replace("/", " ")
        t = f"{t} {len(paths)}"
        titles.append(t)
        paths.append(f"{rng.choice(FOLDERS)}/{t}.md")

    text_bytes = 0
    for i, (title, path) in enumerate(zip(titles, paths)):
        size_factor = 200 if i % 2000 == 7 else 1  # a few huge notes (~0.5-1 MB)
        body = note_body(rng, title, titles, attachments, size_factor)
        full = f"{root}/{path}"
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(body)
        text_bytes += len(body.encode())

    os.makedirs(f"{root}/.obsidian/plugins/dataview", exist_ok=True)
    for name, body in [("app.json", '{"attachmentFolderPath": "Attachments"}'), ("workspace.json", "{}"),
                       ("plugins/dataview/main.js", "x" * 2_000_000)]:
        with open(f"{root}/.obsidian/{name}", "w") as f:
            f.write(body)

    print(f"{root}: {len(paths)} notes ({text_bytes / 1e6:.0f} MB of text), "
          f"{len(attachments)} attachments ({total / 1e9:.2f} GB, sparse)")


if __name__ == "__main__":
    main()
