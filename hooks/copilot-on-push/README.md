# copilot-on-push

After a successful `git push` to a branch with an open pull request, asks Copilot to review the new head with
[`copilot-review`](../../tools/copilot-review/) and tells the agent the result. Every fix push then gets its
review round, and nobody has to remember to request it.

```
copilot-on-push: copilot-review.sh acme/widgets 42 exited 0.
copilot: re-requested on head 3c1d9e07a — ReviewRequestedEvent at 2026-10-20T11:31:44Z by you
```

Works with: Claude Code. DeepSeek Harness through its Claude Code hook bridge (format-compatible, untested).
OpenCode: not supported, it has no shell hooks.

## How it decides

1. The tool call is a shell line with a `git push` in it. The parser is shared with
   [`save-notes-on-push`](../save-notes-on-push/), so chained commands and `git -C <dir> push` count, and `push`
   inside a commit message does not.
2. `gh pr view` finds the pull request for the current branch. No pull request, a closed one or a draft means
   silence.
3. Repositories in `COPILOT_ON_PUSH_SKIP` are skipped silently.
4. Right after a push, GitHub can still report the previous head, and `copilot-review` would then see a head
   Copilot already reviewed and do nothing. The hook waits until the pull request shows the local `HEAD`: 8
   tries, 2 seconds apart. If the head never arrives, the hook tells the agent to run the tool later.
5. A pull request that only bumps packages listed in `COPILOT_ON_PUSH_SKIP_BUMPS` is skipped, and the agent is
   told not to wait for a review. "Only bumps" means two things:
   - the pull request changes nothing but `package.json` and npm, pnpm or yarn lockfiles;
   - every changed `package.json` line sets one of the listed packages.
   Lockfile churn is ignored. A lockfile-only change is still reviewed.
6. Otherwise it runs `copilot-review.sh <owner/repo> <number>` and hands its output to the agent.

A `gh` failure other than "no pull requests found" is reported, not swallowed.

## Configuration

| Variable | Meaning | Default |
|---|---|---|
| `COPILOT_REVIEW_BIN` | Path to `copilot-review.sh` | `~/.agents/tools/copilot-review/copilot-review.sh` |
| `COPILOT_ON_PUSH_SKIP` | Comma-separated `owner/repo` or `owner/*` to leave alone | empty |
| `COPILOT_ON_PUSH_SKIP_BUMPS` | Comma-separated package names whose bump-only pull requests get no review | empty |
| `COPILOT_ON_PUSH_WAIT_TRIES` | How many times to read the pull request head | `8` |
| `COPILOT_ON_PUSH_WAIT_MS` | Pause between reads | `2000` |

Set them in front of the command in `hooks.json`, for example
`COPILOT_ON_PUSH_SKIP=acme/docs COPILOT_ON_PUSH_SKIP_BUMPS=acme-core node "$HOME/.agents/hooks/copilot-on-push/copilot-on-push.cjs"`.

## Install

Requires Node 18 or newer, an authenticated `gh`, and the [`copilot-review`](../../tools/copilot-review/) tool.

```sh
mkdir -p ~/.agents/hooks ~/.agents/tools
cp -R hooks/lib hooks/copilot-on-push ~/.agents/hooks/
cp -R tools/copilot-review ~/.agents/tools/
```

Merge [`hooks.json`](hooks.json) into your harness settings (for Claude Code, the `hooks` key of
`~/.claude/settings.json`). The hook runs on every successful shell call, but it calls `git` and `gh` only after
a push. Its `timeout` of 60 seconds covers the head wait plus the tool's own polling.

## Test

```sh
node --test hooks/copilot-on-push/tests/copilot-on-push.test.mjs
```
