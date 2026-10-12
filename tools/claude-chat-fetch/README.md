# claude-chat-fetch

Fetches one of your own claude.ai conversations and renders it as Markdown, with attachments, pasted content and
artifacts saved beside it, so an agent can read a chat you point it at.

Works with: Claude Code (adapted from a tool in daily use there; the configurable paths are unit-tested). Any
harness that can run a shell command and read a file.

> **Caveat.** This uses claude.ai's undocumented web endpoints with your own browser session. It can break
> without notice, and it is meant only for reading your own conversations.

## Requirements

Node 18 or newer. No dependencies.

## Setup

The tool reads your claude.ai `sessionKey` cookie from a session file:

- default: `~/.config/claude-chat-fetch/session` (or `$XDG_CONFIG_HOME/claude-chat-fetch/session`);
- override: `CLAUDE_CHAT_FETCH_SESSION=/path/to/file`.

Copy the `sessionKey` cookie from a logged-in browser (DevTools → Application → Cookies → `https://claude.ai`), then:

```sh
umask 077
mkdir -p ~/.config/claude-chat-fetch
echo "sessionKey=<paste>" > ~/.config/claude-chat-fetch/session
```

The tool refuses a session file that other users can read. On first use it looks up your organisation and stores
its id in the same file.

## Usage

```sh
node tools/claude-chat-fetch/fetch-chat.mjs https://claude.ai/chat/<uuid>
```

It prints the path of `chat.md`. Next to it are `raw.json`, `meta.json` and a `files/` folder with attachments.
Fetched chats are cached in `~/.cache/claude-chat-fetch/<uuid>/`. `CLAUDE_CHAT_FETCH_CACHE` replaces the
`claude-chat-fetch` folder itself, not its parent; `clean.mjs` only lists and deletes UUID-named folders in it.

```sh
node tools/claude-chat-fetch/clean.mjs                    # list cached chats
node tools/claude-chat-fetch/clean.mjs --older-than 30d   # delete old ones
node tools/claude-chat-fetch/clean.mjs --all --dry-run    # show what --all would delete
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 2 | bad arguments: not a claude.ai chat URL, bad `--older-than` value |
| 3 | session file missing, or no `sessionKey` in it |
| 4 | session file readable by other users (`chmod 600` it) |
| 5 | claude.ai rejected the session: copy a fresh `sessionKey` |
| 6 | chat not found |
| 7 | network error |
| 8 | any other claude.ai error, or no organisation returned |

## Test

```sh
node --test tools/claude-chat-fetch/tests/*.test.mjs
```
