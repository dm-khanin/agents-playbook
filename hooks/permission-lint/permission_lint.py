#!/usr/bin/env python3
"""SessionStart hook: report Claude Code permission rules that cannot work.

Only defects provable from the settings files are reported:
  1. Invalid JSON: Claude Code ignores the whole file, with every setting in it.
  2. Path rules for Write, NotebookEdit, MultiEdit or Glob: Claude Code checks file access against Edit(path) and
     Read(path) only, so it accepts these rules and never consults them.
  3. A rule repeated within one list.
  4. A rule in both allow and deny: deny wins, so the allow entry does nothing.

Whether an MCP tool named in a rule exists is not checked: a hook has no live tool registry, and a hard-coded list
would go stale.

Usage: permission_lint.py [FILE...]   (default: the user's and the project's settings files)
Prints nothing when clean, otherwise {"systemMessage": ...}. Always exits 0: a linter must not break startup.
"""
from __future__ import annotations

import json
import os
import re
import sys

NEVER_CONSULTED = re.compile(r"^(Write|NotebookEdit|MultiEdit|Glob)\((.*)$", re.DOTALL)
REPLACEMENT = {"Write": "Edit", "NotebookEdit": "Edit", "MultiEdit": "Edit", "Glob": "Read"}
LISTS = ("allow", "ask", "deny")


def default_files() -> list[str]:
    files = [os.path.join(os.path.expanduser("~"), ".claude", "settings.json")]
    project = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    for name in ("settings.json", "settings.local.json"):
        candidate = os.path.join(project, ".claude", name)
        if candidate not in files:
            files.append(candidate)
    return files


def shorten(path: str) -> str:
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home + os.sep) else path


def lint_file(path: str) -> list[str]:
    try:
        with open(path, encoding="utf-8") as handle:
            raw = handle.read()
    except OSError:
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        return [f"invalid JSON, so Claude Code ignores the whole file: {exc}"]
    permissions = data.get("permissions") if isinstance(data, dict) else None
    if not isinstance(permissions, dict):
        return []
    lists = {}
    for key in LISTS:
        value = permissions.get(key)
        if isinstance(value, list):
            lists[key] = [rule for rule in value if isinstance(rule, str)]
    findings = []
    for key, rules in lists.items():
        counts: dict[str, int] = {}
        for rule in rules:
            match = NEVER_CONSULTED.match(rule)
            if match:
                replacement = f"{REPLACEMENT[match.group(1)]}({match.group(2)}"
                findings.append(f"'{key}': {rule} is never consulted; use {replacement}")
            counts[rule] = counts.get(rule, 0) + 1
        findings += [f"{rule} appears {count} times in '{key}'" for rule, count in counts.items() if count > 1]
    for rule in sorted(set(lists.get("allow", [])) & set(lists.get("deny", []))):
        findings.append(f"{rule} is in both allow and deny; deny wins")
    return findings


def main(argv: list[str]) -> None:
    lines = []
    for path in argv or default_files():
        findings = lint_file(path)
        if findings:
            lines.append(f"  {shorten(path)}")
            lines += [f"    - {finding}" for finding in findings]
    if lines:
        print(json.dumps({"systemMessage": "\n".join(["Permission-rule linter found issues:", *lines])}))


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception:  # noqa: BLE001 - a linter must never break session start
        pass
    sys.exit(0)
