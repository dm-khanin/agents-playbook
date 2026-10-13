# Working in this repository

You are adding to a public catalog of agent rules, skills, tools and hooks. Everything you commit is published.

## Hard rules

1. Nothing that identifies an employer, client, private system, colleague or anyone's private data. No credentials,
   tokens, cookies, session files or caches, not even as examples.
2. No absolute user paths. Use `~`, `$HOME` or a documented environment variable.
3. English only.
4. Third-party material only under a compatible licence, kept beside it, with a link to the source.
5. Stage explicit paths. Never `git add -A` or `git add .`. Read `git diff --cached --name-only` before committing.

## Where things go

| Kind | Path | Required |
|---|---|---|
| Rule | `global/AGENTS.md` | A numbered rule: directive, reason, how to apply, about five lines |
| Skill | `skills/<name>/` | `SKILL.md` with `name` (kebab-case, ≤ 64, equal to the directory) and `description`; optional `scripts/`, `references/` |
| Tool | `tools/<name>/` | `README.md`, source, `tests/` |
| Hook | `hooks/<name>/` | script, `hooks.json` in Claude Code format, `README.md`, `tests/` |
| Decision | `docs/decisions.md` | A new numbered record |

- A slash command is written as a skill.
- Every item states `Works with:` — harnesses it was actually used with first, then format-compatible but untested ones.
- Add the item to the table in `README.md` in the same commit.

## Before every commit

    python3 tools/leak-guard/leak_scan.py --staged
    python3 scripts/skill_lint.py
    sh scripts/run-tests.sh

All three must pass. The test runner sees tracked files only, so stage new tests first. If the leak scan flags
something that is genuinely fine, add an exact `<path> <pattern-id>` line to `.leakguard-allow` and give the
reason in the commit message, describing the match in words: the history scan reads commit messages too, so
quoting the flagged string there is a new finding. A private-pattern match is never allowed: remove the content.

## Commits

Conventional Commits, one item per commit, tests in a separate `test:` commit.

## One-time setup per clone

    git config core.hooksPath .githooks

Create a git-ignored `.leakguard.local` with private patterns, one regular expression per line.
