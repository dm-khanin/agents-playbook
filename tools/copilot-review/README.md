# copilot-review

Scripts for running a GitHub Copilot review loop from the command line. `copilot-review.sh` requests a review and
proves the request registered, so an agent can ask for a fresh round after every fix push and nobody has to press
the re-request button. The other four read the result, list the findings Copilot hides outside review threads,
answer and resolve each thread, and wait for the next review.

```
$ copilot-review.sh acme/widgets 42
copilot: re-requested on head 3c1d9e07a — ReviewRequestedEvent at 2026-10-20T11:31:44Z by you
the review usually lands within ~10 min; it is signed by copilot-pull-request-reviewer
```

Works with: Claude Code. Any harness with a shell can call it the same way; untested there.

## The review loop

| Step | Script | What it does |
|---|---|---|
| Request | `copilot-review.sh <owner/repo> <pr> [--force]` | Requests or re-requests Copilot, see below |
| Wait | `copilot-review-watch.sh <owner/repo> <pr> [poll_seconds] [max_minutes]` | Exits with one line when a newer Copilot review appears; exits 0 with a timeout line after `max_minutes` (default 30) |
| Read | `pr-state.sh <owner/repo> <pr>` | Head, CI and each check, open threads with path and author, pending requests, recent reviews with the commit each saw, whether Copilot saw the head, and a count of body findings |
| List | `pr-findings.sh <owner/repo> <pr> [--full]` | The findings in the latest Copilot review body, with severity, `file:line` and title; `--full` adds the text |
| Answer | `pr-thread-close.sh <owner/repo> <pr> <comment-id> <reply-file>` | Replies in the thread holding the comment, then resolves it |

```
$ pr-state.sh acme/widgets 42
...
threads: 6 total, 0 open
copilot: latest review on 3c1d9e07a at 2026-10-20T11:39:12Z, saw the head
copilot body findings: 1 (missed 1, suppressed 0), effort Balanced — list them: pr-findings.sh acme/widgets 42
```

Three traps the loop is built around:

- **Zero open threads is not zero findings.** Copilot keeps some findings in the review body: under
  "N previously missed issue(s)", "Suppressed comments (N)" and similar `<details>` blocks, with no thread to
  resolve. `lib/copilot_body.py` parses the five spellings seen on real reviews in two shapes, nested and flat,
  and strips the zero-width spaces Copilot puts inside paths. `pr-state.sh` counts them, `pr-findings.sh` lists them.
- **Copilot signs differently per API surface.** Inline review comments come from `Copilot`; the REST reviews
  endpoint says `copilot-pull-request-reviewer[bot]` and GraphQL says `copilot-pull-request-reviewer`. A watcher
  filtering reviews by the inline login never fires. `copilot-review-watch.sh` matches `copilot` case-insensitively,
  and refuses to arm when the baseline query fails. Run it in the background and wait for it to exit.
- **A reply and a resolve can half-happen.** `pr-thread-close.sh` finds the thread first and writes nothing if the
  comment is in none; then it requires the reply's `html_url`, then `isResolved == true`. A failure after the
  reply says that the reply exists and the thread is still open. The comment id is the numeric `id` of the
  thread's top-level comment as `gh api repos/<owner>/<repo>/pulls/<pr>/comments` lists it.

Every script takes the repository as `owner/repo`; there is no default owner. Usage errors exit 2 without calling
`gh`; an API failure exits non-zero.

## Requesting a review

### Why

- Copilot reviews a pull request when it is requested, not on every push. Once a request has been used up, new
  commits trigger nothing, and the UI offers a re-request button.
- That button posts a session-bound form with a per-page CSRF token, so it cannot be replayed from a CLI.
- The public GraphQL API accepts bots:
  - `rerequestReviews(botIds:)` does what the button does;
  - `requestReviewsByLogin(botLogins:)` adds Copilot to a pull request it has not seen.
- `gh pr view --json reviewRequests` and the REST `requested_reviewers` endpoint never list a bot, so a pending
  Copilot request looks like no request at all. The script reads the state through GraphQL `... on Bot` instead.

### What it does

| State | Action |
|---|---|
| Copilot already pending | Nothing. A request is never doubled, even with `--force` |
| Copilot's latest review saw the head commit | Nothing, unless `--force` |
| Copilot reviewed an older commit | `rerequestReviews` |
| Copilot never reviewed the pull request | `requestReviewsByLogin` with `union: true`, so other reviewers stay |
| Draft or closed pull request | Refuses |

A mutation that returns `ok` proves nothing by itself. After the mutation, the script waits for a new
`ReviewRequestedEvent` for the bot and fails if none appears.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Requested, or nothing to do |
| 1 | Refused, or the request did not register |
| 2 | Usage error |

## Measured

On 2026-10-20 there were four requests on one pull request: two from the UI and two through the GraphQL mutations
this script uses. Each one produced a Copilot review 7.7 to 7.8 minutes later.

The `rerequestReviews` path is measured. The first-request path (`requestReviewsByLogin`) follows the public
schema but has not been measured yet.

## Review effort

Copilot's effort level (Lite, Balanced) is a per-pull-request setting. Each user's default is set at
<https://github.com/settings/copilot/code_review>. The mutations take no effort argument, so the review runs at the
pull request's level. Copilot names that level at the end of the review body, for example `Review effort: Balanced`.

## Install

```sh
mkdir -p ~/.agents/tools
cp -R tools/copilot-review ~/.agents/tools/
```

Keep `lib/` next to the scripts: `pr-state.sh` and `pr-findings.sh` find the parser there.

Requires `bash`, `python3` and an authenticated `gh` whose token may request reviewers and resolve threads on the
repository. `gh` brings its own jq for `--jq`; `pr-state.sh` and `pr-findings.sh` also call `jq` directly.

So that Claude Code can run it without a prompt, allow the script itself, not raw `gh api graphql`: a rule for
that would open every GraphQL write. The rule matches the command text, so the agent must call the script by
exactly this spelling:

```json
{ "permissions": { "allow": [
  "Bash(~/.agents/tools/copilot-review/copilot-review.sh:*)",
  "Bash(~/.agents/tools/copilot-review/copilot-review-watch.sh:*)",
  "Bash(~/.agents/tools/copilot-review/pr-state.sh:*)",
  "Bash(~/.agents/tools/copilot-review/pr-findings.sh:*)",
  "Bash(~/.agents/tools/copilot-review/pr-thread-close.sh:*)"
] } }
```

A matching line for the agent's instructions:

> After opening a pull request, and after each push that answers review, run
> `~/.agents/tools/copilot-review/copilot-review.sh <owner/repo> <pr>`. The round is done when a review signed by
> `copilot-pull-request-reviewer` has seen the head, `pr-state.sh` shows no open threads and no body findings,
> and every thread was answered with `pr-thread-close.sh`.

## Test

```sh
python3 -m unittest discover -s tools/copilot-review/tests -t tools/copilot-review/tests
```

The tests put a fake `gh` and a no-op `sleep` first on `PATH`, plus a fake `date` for the watcher, so a watch
polls a fixed number of times. The fake `gh` answers with canned responses and runs the script's own `--jq` filter
through `jq`, so the filters are tested too. Requires `jq`.
