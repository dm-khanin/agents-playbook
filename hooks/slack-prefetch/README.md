# slack-prefetch

When a prompt contains a Slack message link, this hook downloads the files attached to that thread into a private
local cache and tells the agent where they are, so it can read a screenshot, a CSV or a PDF without asking you to
download it. It follows links to other threads two levels deep. Message text is not fetched: use your Slack
connector for that.

Works with: Claude Code (the private hooks this rewrite replaces are in daily use there; this version is
unit-tested against a fake Slack API). DeepSeek Harness through its Claude Code hook bridge, which supports
UserPromptSubmit (format-compatible, untested). Gemini CLI would need the event renamed (untested).

## Slack token

The hook needs a user token (`xoxp-…`), because only a user token can download files from the channels you are
in. Create an internal app for your own workspace at <https://api.slack.com/apps>, add these user token scopes,
install it, and copy the User OAuth Token:

| Scope | For |
|---|---|
| `channels:history`, `groups:history`, `im:history`, `mpim:history` | reading threads in public, private and direct conversations |
| `files:read` | downloading their attachments |

Keep the token in a file only you can read, which the hook finds at `${XDG_CONFIG_HOME:-~/.config}/slack-prefetch/token`
(or the path in `SLACK_PREFETCH_TOKEN_FILE`):

```sh
umask 077
mkdir -p ~/.config/slack-prefetch
printf '%s\n' '<paste the token>' > ~/.config/slack-prefetch/token
```

`SLACK_USER_TOKEN` works too, but an exported variable is inherited by every command the agent runs, so prefer the
file. The token is only ever sent over HTTPS to `slack.com` and `files.slack.com`, redirects included; a file
whose URL points elsewhere is skipped.

## Install

Requires Python 3.9 or newer.

```sh
mkdir -p ~/.agents/hooks
cp -R hooks/slack-prefetch ~/.agents/hooks/
```

Merge [`hooks.json`](hooks.json) into the `hooks` key of `~/.claude/settings.json`. It sets a 90-second timeout:
the default for prompt hooks is shorter, and a hook that times out loses its output.

## Behaviour

| Limit | Value |
|---|---|
| linked threads followed | 2 levels deep, at most 20 threads per prompt |
| per file | 25 MB, by declared and by received size |
| per prompt | 100 MB |
| time | 60 seconds of work, inside the 90-second hook timeout |
| skipped | audio, video, deleted and external files, and anything not hosted on Slack |

| Variable | Default | Meaning |
|---|---|---|
| `SLACK_PREFETCH_OFF` | unset | `1` turns the hook into a no-op |
| `SLACK_PREFETCH_TTL_DAYS` | 7 | cached files unused for longer are deleted |
| `SLACK_PREFETCH_TOKEN_FILE` | see above | where the token file is |

Files are cached in `${XDG_CACHE_HOME:-~/.cache}/slack-prefetch/` (mode 0700, files 0600), named by Slack file id.
The hook never blocks a prompt: problems become a line in the context, and it always exits 0.

## Know before you install

- **Downloaded files are untrusted input.** Anyone who can post in a linked thread decides what the agent reads; the
  context line says so, and the agent should treat the files as data, not instructions.
- **It runs on every prompt-like turn**, not only yours: subagent reports, scheduled and looped turns, and messages
  from other sessions also trigger it when they contain a Slack link.
- **A prompt can wait** up to the 60-second budget while files download.
- Links of the form `https://<workspace>.slack.com/archives/<channel>/p<timestamp>` are recognised, including
  enterprise workspaces and reply links with `thread_ts`. Links to the Slack web client (`app.slack.com/client/…`)
  are not.

## Test

```sh
python3 -m unittest discover -s hooks/slack-prefetch/tests -t hooks/slack-prefetch/tests
```
