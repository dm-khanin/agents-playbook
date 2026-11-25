# codex-review

Runs OpenAI Codex as an independent reviewer of a branch: read-only, non-interactive, the result written to a
markdown file. It is meant to sit next to the reviewers an agent already runs, so that a model from another family
reads the same diff without seeing the agent's own conclusions.

```
$ codex-review.sh ~/src/widgets --context rulings.md
codex-review: widgets feat/retry-budget 3c1d9e07a vs origin/main, gpt-6.2-sol/high, pr context: PR #42, timeout 2400s
codex-review: done in 3m54s; usage not reported
~/.claude/codex-reviews/widgets-feat-retry-budget-3c1d9e0.md
```

The review is a short verdict plus findings tagged `[P1]` to `[P3]`, each with `file:line` and a concrete scenario.

Works with: Claude Code. Any harness with a shell can call it the same way; untested there.

## Usage

`codex-review.sh <worktree> [options]`

| Option | Default | Meaning |
|---|---|---|
| `--base <ref>` | the remote's HEAD | The branch the pull request targets. It is fetched first; the review covers merge base..HEAD |
| `--since <sha>` | | A fix round: review only `<sha>..HEAD`, with the rest of the branch as context |
| `--context <file>` | | Appended to the prompt as background, see below |
| `--effort <level>` | `high` | `low`, `medium`, `high`, `xhigh` or `max` |
| `--model <slug>` | `$CODEX_REVIEW_MODEL`, else `gpt-6.2-sol` | The review model |
| `--out <file>` | `~/.claude/codex-reviews/<repo>-<branch>-<sha7>[-since-<sha7>].md` | Where the review goes; the events (`.jsonl`), stderr (`.err`) and prompt (`.prompt.txt`) land beside it |
| `--timeout <min>` | `40` | Codex is killed after this |

| Exit | Meaning |
|---|---|
| 0 | Review written; its path is the last line of stdout |
| 1 | Codex failed, timed out, or exited 0 without writing a review |
| 2 | Usage error, or nothing to review; Codex was not called |

A worktree with modified tracked files is refused: Codex reads the files on disk, so its review would not match
HEAD. Untracked files are fine.

## What goes into the prompt

Without any option, the prompt carries:
- the range and the commands to read it;
- the pull request's title and body, when `gh pr view` finds one for the branch (the first stderr line says
  `pr context: PR #N`, or `none`);
- the house rules: `CLAUDE.md` and `AGENTS.md` in the worktree and `CLAUDE.local.md` in the main checkout, which a
  linked worktree does not have; Codex follows the topic docs those files index on its own;
- the `## Code` and `## Testing` sections of `$CODEX_REVIEW_CONVENTIONS` (default `~/.claude/CLAUDE.md`), inlined
  so that the rest of that file stays out of the prompt;
- with `CODEX_REVIEW_WORKSPACE_DOCS` set, the workspace maps, and an instruction to find the consumers of a changed
  API, payload, column or enum in the sibling repositories. Many independent repositories side by side is where a
  diff-only review is blindest.

`--context` is for facts of intent: acceptance criteria, the spec, trade-offs already decided. Keep your own
findings and the other reviewers' out of it: the point of this reviewer is that it is not anchored on them.

## Traps, measured on 2026-11-25 with Codex CLI 0.171

- **Review mode ignores `-m`.** It takes its model from the config key `review_model`. A bogus `-m` with a valid
  `review_model` ran; the reverse failed with "model is not supported when using Codex with a ChatGPT account". The
  script sets both.
- **`codex exec review --base` refuses a custom prompt** (`the argument '--base <BRANCH>' cannot be used with
  '[PROMPT]'`). The script computes the merge base itself and passes the range inside the custom instructions; review
  mode keeps its own reviewer prompt and output format.
- **Effort:** the script passes `model_reasoning_effort`. The CLI has no review-specific effort key, and nothing
  measured shows whether review mode honours this one.
- **Usage is not reported** with a ChatGPT sign-in: every usage counter in the events is 0. The script says "usage
  not reported" instead of printing zeros.
- **Read-only means no writes, not no reads.** On a trial run Codex read files outside the worktree and ran the test
  suite with dependencies it found in another checkout, patching out file writes; the worktree stayed clean. Treat
  "tests pass" in a review as unverified, and remember that whatever it opens is sent to OpenAI.
- **`--ignore-user-config`** keeps a desktop app's MCP servers and notify hook out of the run; the sign-in still
  comes from `~/.codex`.

## Measured

On 2026-11-25, a full review of a 677-line diff took 3 min 54 s at `high`, and a fix round over one commit took
1 min 30 s at `medium`. Run it in the background: a harness that caps a foreground command at 10 minutes would cut
off a slow run, and the agent can do its own review in the meantime.

## Install

```sh
mkdir -p ~/.agents/tools
cp -R tools/codex-review ~/.agents/tools/
```

Requires `bash`, `git`, `python3`, `timeout` (GNU coreutils, or the one in recent macOS) and a signed-in Codex CLI
(`codex login status`). `gh` is optional; without it the pull request's description is not attached. On macOS the
CLI may ship inside the ChatGPT app and not be on `PATH`; the script falls back to that location, or set `CODEX_BIN`.

So that Claude Code can run it without a prompt, allow the script by exactly the spelling the agent will use:

```json
{ "permissions": { "allow": [
  "Bash(~/.agents/tools/codex-review/codex-review.sh:*)"
] } }
```

A matching line for the agent's instructions:

> When you review a branch, start `~/.agents/tools/codex-review/codex-review.sh <worktree>` in the background at
> the same time, and rerun it with `--since <sha>` after each fix. Verify every finding in the code before acting on
> it. Never paste its text into a pull request: its locations are local paths. Give it only facts of intent in
> `--context`, never your own findings.

## Test

```sh
bats tools/codex-review/tests
```

The tests put a fake `codex` and a fake `gh` first on `PATH` and build a throwaway origin, clone and linked
worktree, with the base branch moved on after the fork, so that a review of the base tip instead of the merge base
fails a test.
