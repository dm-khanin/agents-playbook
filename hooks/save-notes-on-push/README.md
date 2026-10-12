# save-notes-on-push

After a successful `git push`, reminds the agent to write or update a session note with the
[`save-notes`](../../skills/save-notes/SKILL.md) skill. It stays silent everywhere else: other tools, other git
commands, `push` appearing inside a commit message or a search pattern, and repositories without notes.

Works with: Claude Code (used). DeepSeek Harness through its Claude Code hook bridge (format-compatible,
untested). Gemini CLI would need the event renamed to `AfterTool` (untested). OpenCode: not supported, it has no
shell hooks.

## How it decides

1. The tool call is a shell command whose git subcommand is `push`, even after git-level flags such as
   `git -C <dir> push` or `git -c key=value push`.
2. The repository is the `-C` directory if given, otherwise the working directory. The hook walks up at most five
   levels looking for `.agents/notes/INDEX.md` or `.claude/notes/INDEX.md`. That file is the opt-in.
3. If both hold, it returns the reminder as additional context for the agent.

## Install

Requires Node 18 or newer and the `save-notes` skill.

```sh
mkdir -p ~/.agents/hooks
cp -R hooks/save-notes-on-push ~/.agents/hooks/
```

Merge [`hooks.json`](hooks.json) into your harness settings (for Claude Code, the `hooks` key of
`~/.claude/settings.json`). Opt a repository in with:

```sh
mkdir -p .agents/notes && touch .agents/notes/INDEX.md
echo '.agents/notes/' >> .gitignore
```

## Test

```sh
node --test hooks/save-notes-on-push/tests/save-notes-on-push.test.mjs
```
