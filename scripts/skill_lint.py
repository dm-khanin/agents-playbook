#!/usr/bin/env python3
"""Check every skill under skills/ against the rules all supported harnesses share.

The strictest common subset: a directory per skill holding SKILL.md, YAML
frontmatter with `name` (kebab-case, 1-64 chars, equal to the directory name)
and a non-empty `description` of at most 1024 characters, one level deep.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
MAX_NAME = 64
MAX_DESCRIPTION = 1024
BLOCK_MARKERS = {">", ">-", ">+", "|", "|-", "|+"}


def parse_frontmatter(text: str) -> dict[str, str] | None:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        return None
    fields: dict[str, str] = {}
    key = None
    for line in lines[1:end]:
        match = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if match:
            key, value = match.group(1), match.group(2).strip()
            fields[key] = "" if value in BLOCK_MARKERS else value.strip("'\"")
        elif key and line[:1] in (" ", "\t"):
            fields[key] = f"{fields[key]} {line.strip()}".strip()
    return fields


def check_skill(skill_dir: Path) -> list[str]:
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.is_file():
        return ["missing SKILL.md"]
    problems = []
    nested = [p for p in skill_dir.rglob("SKILL.md") if p != skill_md]
    if nested:
        problems.append("nested SKILL.md is not discovered by every harness")
    fields = parse_frontmatter(skill_md.read_text(encoding="utf-8"))
    if fields is None:
        return problems + ["missing frontmatter"]
    name = fields.get("name", "")
    if not NAME_RE.match(name) or len(name) > MAX_NAME:
        problems.append(f"name '{name}' must be kebab-case, 1-{MAX_NAME} characters")
    if name != skill_dir.name:
        problems.append(f"name '{name}' does not match directory '{skill_dir.name}'")
    description = fields.get("description", "")
    if not description:
        problems.append("description is missing or empty")
    elif len(description) > MAX_DESCRIPTION:
        problems.append(f"description is {len(description)} characters, limit {MAX_DESCRIPTION}")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".", help="repository root (default: current directory)")
    args = parser.parse_args(argv)
    skills = Path(args.root) / "skills"
    if not skills.is_dir():
        print(f"skill-lint: no skills/ directory under {args.root}", file=sys.stderr)
        return 2
    failures = 0
    entries = sorted(e for e in skills.iterdir() if not e.name.startswith("."))
    for entry in entries:
        problems = check_skill(entry) if entry.is_dir() else ["skills must be directories"]
        for problem in problems:
            print(f"skills/{entry.name}: {problem}")
        failures += bool(problems)
    print(f"skill-lint: {len(entries) - failures} ok, {failures} failing", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
