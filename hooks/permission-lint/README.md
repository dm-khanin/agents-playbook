# permission-lint

At session start, reports Claude Code permission rules that cannot do what they say. It stays silent when the
settings are clean and never delays or breaks startup.

Works with: Claude Code (the linter this version comes from runs at every session start there; this version is
unit-tested). Claude Code only: the permission format is Claude Code's.

## Checks

| Finding | Why it matters |
|---|---|
| invalid JSON | Claude Code ignores the whole file, every setting in it included |
| a path rule for `Write`, `NotebookEdit`, `MultiEdit` or `Glob` | Claude Code checks file access against `Edit(path)` and `Read(path)` only, so the rule is accepted and never consulted; the message names the rule to use instead |
| a rule repeated in one list | dead weight that hides real changes in review |
| a rule in both `allow` and `deny` | deny wins, so the allow entry does nothing |

It reads `~/.claude/settings.json` and the project's `.claude/settings.json` and `.claude/settings.local.json`.
Whether an MCP tool named in a rule exists is not checked: a hook has no live tool registry to compare against.
The path-rule behaviour is from the Claude Code permissions documentation, checked against version 2.1.296.

## Install

Requires Python 3.9 or newer.

```sh
mkdir -p ~/.agents/hooks
cp -R hooks/permission-lint ~/.agents/hooks/
```

Merge [`hooks.json`](hooks.json) into the `hooks` key of `~/.claude/settings.json`. To lint other files:
`python3 ~/.agents/hooks/permission-lint/permission_lint.py path/to/settings.json`.

## Test

```sh
python3 -m unittest discover -s hooks/permission-lint/tests -t hooks/permission-lint/tests
```
