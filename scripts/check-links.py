#!/usr/bin/env python3
"""CI helper: every relative Markdown link must point to a file that exists.

Checks README*.md, docs/**/*.md and prompts/*.md for links like
[text](path/to/file.md) or ![alt](assets/x.svg). Absolute URLs, mailto: and
pure anchors are ignored. Run from the repository root.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
SKIP = ("http://", "https://", "mailto:", "#", "tel:", "ftp://")

problems: list[str] = []
checked = 0
files = [p for p in sorted(ROOT.glob("**/*.md")) if ".git" not in p.parts]

for md in files:
    text = md.read_text(encoding="utf-8")
    for raw in LINK.findall(text):
        target = raw.strip()
        if not target or target.startswith(SKIP):
            continue
        target = target.split()[0].split("#", 1)[0]
        if not target:
            continue
        resolved = (md.parent / target).resolve()
        checked += 1
        if not resolved.exists():
            problems.append(f"{md.relative_to(ROOT)}: broken link -> {target}")

print(f"checked {checked} relative links in {len(files)} markdown files")
if problems:
    print("\n".join(problems))
    sys.exit(1)
print("all relative links resolve")
