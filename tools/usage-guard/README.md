# usage-guard

Pauses Claude Code sessions just before a claude.ai plan limit runs out and wakes them when the window resets. It is
for running several sessions and subagents in parallel on a subscription with extra usage turned on: there the last
few percent of a window roll into paid usage instead of stopping, usually while nobody is watching.

Works with: Claude Code only. It needs the status line payload's `rate_limits` and `asyncRewake` hooks, which no
other harness has.

## How it works

```
status line payload ──feed──▶ ~/.claude/usage-guard/state.json ◀──── read by every session
                                                       │
before each tool call ──check──▶ window ≥ threshold? ──yes──▶ {"continue": false}: the turn ends, the tool never runs
                      └─wake (asyncRewake)──▶ sleeps until the reset ──▶ exit 2 ──▶ the session wakes and continues
```

- **feed.** Claude Code shows plan usage in one place only: the JSON it pipes to the status line command
  (`rate_limits.five_hour` and `rate_limits.seven_day`, each with `used_percentage` and `resets_at`). One line in
  your status line script merges it into a state file every session reads. Usage never falls inside a window, so
  the merge keeps the highest reading of each window: a session that has not called the API for a while cannot
  pull the shared value down.
- **check.** A PreToolUse hook on every tool. When a window is at or over the threshold (97% by default) it returns
  `continue: false`: the turn ends at a tool-call boundary, the tool does not run, and no further model call is
  made. A subagent that hits it ends at once, without a report.
- **wake.** The same event's `asyncRewake` hook. It sleeps until the blocking window resets, adds a delay and some
  jitter, and exits 2, which wakes the session with a message to continue where it stopped. A subagent's waker wakes
  the main session. However many agents of one session were stopped, only the first waker to claim the session's
  pause marker wakes it.
- **Weekly window.** Guarded too. When its reset is further off than the wake hook may wait (about 5 h 50 min), the
  session stays paused until you resume it.
- **Notifications.** One message per window when sessions start pausing and one when they resume, through any
  command you configure. A Telegram sender is included.
- **Fails open.** Any error in a hook lets the tool call through and lands in `events.log`.

## Install

```sh
mkdir -p ~/.agents/tools
cp -R tools/usage-guard ~/.agents/tools/
```

1. Merge [`hooks.json`](hooks.json) into the `hooks` key of `~/.claude/settings.json`. Keep the wake hook's
   `timeout` (21600 s) above `max_auto_wait_s`.
2. Feed it from your status line. Add one line right after your script reads its input:

   ```sh
   input=$(cat)
   python3 "$HOME/.agents/tools/usage-guard/guard.py" feed <<<"$input" >/dev/null 2>&1 || true
   ```

   The bundled [`statusline`](../statusline/) tool reads its input the same way. Without a status line command the
   guard has no data and never pauses anything.
3. Optional notifications: create `~/.claude/usage-guard/config.json`.

   ```json
   { "notify_command": ["~/.agents/tools/usage-guard/notify-telegram.sh"] }
   ```

   The Telegram sender reads the same credentials as [`notify-telegram`](../../hooks/notify-telegram/):
   `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`, from the environment or from
   `~/.config/agents-playbook/telegram.env`.

Requires `python3` 3.9 or newer; the Telegram sender also needs `bash` and `curl`.

## Configuration

`~/.claude/usage-guard/config.json`, every key optional:

| Key | Default | Meaning |
|---|---|---|
| `threshold` | `97` | Percent of a window at which sessions pause |
| `windows` | `["five_hour", "seven_day"]` | Windows to guard; `5h` and `7d` work too |
| `resume_delay_s` | `90` | Wait after the reset before waking a session |
| `resume_jitter_s` | `60` | Random extra wait, so parallel sessions do not all wake in the same second |
| `max_auto_wait_s` | `21000` | Longest automatic wait; a later reset needs a manual resume |
| `notify_command` | none | Command as a list; the message is appended as its last argument |

## Commands

```sh
python3 ~/.agents/tools/usage-guard/guard.py status          # windows, overrides, paused sessions, waiting wakers
python3 ~/.agents/tools/usage-guard/guard.py off [5h|7d|all]  # run past the threshold until the current window resets
python3 ~/.agents/tools/usage-guard/guard.py on               # drop the override
touch ~/.claude/usage-guard/disabled                          # kill switch: hooks do nothing while it exists
```

`off` also calls off the pending wakes: tell the paused sessions to continue yourself.

## Check it on your machine

A probe fakes a blocking window for one session only; every other session keeps working.

```sh
ls -t ~/.claude/projects/*/*.jsonl | head -1                  # the newest transcript's name is the session id
python3 ~/.agents/tools/usage-guard/guard.py probe <session-id> --pct 99 --in 45
```

Then ask that session to run any command. The command must not run, the turn must end, and about 50 seconds later
the session must wake with the continue message. `events.log` shows the pause, the resume and each notification's
exit status. Measured on Claude Code 2.1.303: the blocked command did not run and the session woke 5 s after the fake
reset (the probe's own delay), both when the main session made the call and when a subagent did.

## Limits

- Each tool call costs about 45 ms more: one Python start for `check`; `wake` runs in the background.
- Only tool calls are gated. Between a window crossing the threshold and each session's next tool call, usage keeps
  growing, so leave headroom for the number of sessions you run in parallel.
- A workflow script can still start new agents during a pause; each of them stops at its first tool call.
- The shared reading is as fresh as the last API response any session's status line has seen.
- A session closed while paused is not resumed.

## Test

```sh
python3 -m unittest discover -s tools/usage-guard/tests -t tools/usage-guard/tests
```

The tests run the hooks as Claude Code does, with JSON on stdin, against a temporary `USAGE_GUARD_HOME`, and take
about 40 seconds because the wake tests sleep through real two-to-four-second windows.
