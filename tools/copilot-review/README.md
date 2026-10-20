# copilot-review

Requests a GitHub Copilot code review on a pull request from the command line and proves the request registered.
With it, an agent can ask for a fresh Copilot round after every fix push. Nobody has to press the re-request button.

```
$ copilot-review.sh acme/widgets 42
copilot: re-requested on head 3c1d9e07a — ReviewRequestedEvent at 2026-10-20T11:31:44Z by you
the review usually lands within ~10 min; it is signed by copilot-pull-request-reviewer
```

Works with: Claude Code. Any harness with a shell can call it the same way; untested there.

## Why

- Copilot reviews a pull request when it is requested, not on every push. Once a request has been used up, new
  commits trigger nothing, and the UI offers a re-request button.
- That button posts a session-bound form with a per-page CSRF token, so it cannot be replayed from a CLI.
- The public GraphQL API accepts bots:
  - `rerequestReviews(botIds:)` does what the button does;
  - `requestReviewsByLogin(botLogins:)` adds Copilot to a pull request it has not seen.
- `gh pr view --json reviewRequests` and the REST `requested_reviewers` endpoint never list a bot, so a pending
  Copilot request looks like no request at all. The script reads the state through GraphQL `... on Bot` instead.

## What it does

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

Requires `bash` and an authenticated `gh` whose token may request reviewers on the repository. `gh` brings its own
jq.

So that Claude Code can run it without a prompt, allow the script itself, not raw `gh api graphql`: a rule for
that would open every GraphQL write. The rule matches the command text, so the agent must call the script by
exactly this spelling:

```json
{ "permissions": { "allow": ["Bash(~/.agents/tools/copilot-review/copilot-review.sh:*)"] } }
```

A matching line for the agent's instructions:

> After opening a pull request, and after each push that answers review, run
> `~/.agents/tools/copilot-review/copilot-review.sh <owner/repo> <pr>`. The round is done when a review signed by
> `copilot-pull-request-reviewer` has seen the head.

## Test

```sh
python3 -m unittest discover -s tools/copilot-review/tests -t tools/copilot-review/tests
```

The tests put a fake `gh` and a no-op `sleep` first on `PATH`. The fake `gh` answers with canned GraphQL responses
and runs the script's own `--jq` filter through `jq`, so the filter is tested too. Requires `jq`.
