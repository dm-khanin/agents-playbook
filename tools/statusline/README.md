# statusline

A one-line status bar for Claude Code: working directory, model, git branch with a `*` when the tree is dirty,
context-window use as a coloured bar, the five-hour rate-limit use with time to reset, session cost and duration.

```
📁 ~/project  🤖 Model Q  🌿 feature-x*  🧠 80k/200k ████░░░░░░ 40%  ⏱ 1:05
```

Works with: Claude Code only. None of the other harnesses has a scriptable status line.

## Install

```sh
mkdir -p ~/.agents/tools
cp -R tools/statusline ~/.agents/tools/
```

Then in `~/.claude/settings.json`:

```json
{ "statusLine": { "type": "command", "command": "~/.agents/tools/statusline/statusline.sh" } }
```

Requires `bash`, `jq` and `git`. Segments whose data is missing from the payload are left out.

## Test

```sh
python3 -m unittest discover -s tools/statusline/tests -t tools/statusline/tests
```
