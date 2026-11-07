---
name: roll-out-a-library-release
description: Roll a new release of a shared internal library out to every service that depends on it - bump the pin in each repository, merge through CI and release-please, then deploy and verify on Heroku, Clever Cloud or container-image functions behind Terraform/Terragrunt. Use when a shared package has been released and its consumers must pick it up, or when asked to bump and deploy a dependency across several repositories.
argument-hint: "in <repos...> <version> <branch> [issue] <commit message>"
---

# Roll out a library release

Works with: Claude Code (distilled from two rollout skills in daily use there, one for Heroku and Clever Cloud
services and one for container functions); OpenCode, Gemini CLI, DeepSeek Harness (format-compatible, untested).

A shared library is released once and deployed many times. Each consumer has its own CI, its own release tool and
its own hosting, and each of those can report success for a deploy that never happened. This skill walks every
consumer from the pin bump to evidence that the new code is what serves traffic. It applies the gates in
[`gate-a-deploy`](../gate-a-deploy/SKILL.md) to one concrete pipeline: bump, CI, release-please, deploy, verify.

## Before the first run: the inventory

Copy [`references/inventory.example.md`](references/inventory.example.md) to `references/inventory.md` beside this
file and fill it in: library name, every consumer repository with its aliases, default branch, local path, host,
apps or functions per stage, deploy method, health URL and the HTTP codes a healthy app answers.

The inventory is the only source of truth for app names and deploy methods. Never guess an app or a function from a
naming pattern. A consumer that is not in the inventory is silently skipped by `all`, so when you meet one, say so
and add it before you continue.

## Arguments

`in <repos...> <version> <branch> [issue] <commit message...>`

1. Skip `in`. Collect repository names or aliases until a token that starts with a digit: that is the version.
2. The next token is the branch name.
3. The next token is an issue reference if it matches the inventory's issue format (an id or a tracker URL);
   otherwise it starts the commit message.
4. Everything left is the commit message. Its type comes from the branch prefix: `feat/` gives `feat`, `fix/` gives
   `fix`.

Example: `in api workers 4.12.0 fix/bump-lib 1234 pick up the retry fix`.

## Step 1: bump each repository

Run the repositories in parallel, one agent per repository at most.

**Branch.** Check the branch locally (`git branch --list`) and on origin (`git ls-remote --heads origin`):

| Exists | Do |
|---|---|
| nowhere | `git checkout <default> && git pull && git checkout -b <branch>` |
| only on origin | `git fetch origin <branch> && git checkout -b <branch> origin/<branch>` |
| only locally | `git checkout <branch>` |
| both | `git checkout <branch> && git pull` |

A branch that already existed carries earlier work and maybe an open pull request: add the bump as one more commit.

**Pin.**

1. Set the exact released version in the manifest. No range operator and no git reference: a range resolves
   differently per install, and a git pin does not survive a release.
2. Install, then read the version the lockfile actually resolved. A cached or stale resolution is common.
3. Run the build. Commit and push only after it passes. Stage the manifest and lockfile by path.
4. If the build breaks, fix it on the same branch, then stop and describe the break and the fix to the user. Do not
   merge a pull request that needed code changes without their approval.

**Commit type must cut a release.** Use `fix:` or `feat:`, chosen by what the new library version changes.
`chore:` cuts no release, so nothing new is built and the deploy steps have nothing to ship. If a `chore:` bump has
already merged, add an empty `fix:` commit through a pull request. Never push to the default branch directly.

**Pull request.** Reuse an open one for the branch (`gh pr list --head <branch>`). Link the issue only if the body
does not link it already. Follow the inventory's conventions for assignee and reviewers.

## Step 2: CI, merge, release

Poll every 30 seconds, with a 10-minute timeout per wait.

1. Wait for the checks of your head commit: `gh pr checks <pr>`.
2. If the default branch moved, rebase, `push --force-with-lease`, and wait again.
3. Merge: `gh pr merge <pr> --merge`.
4. Find the release-please pull request. Use `gh pr list --head release-please--branches--<default>` first, then
   filter open pull requests by the title prefix `chore(<default>): release`. Search and label filters lag behind.
   Some repositories use a longer branch name, `release-please--branches--<default>--components--<name>`.
5. Confirm it contains your commit before merging. Never merge a stale release pull request.
6. Merge it, then record its merge commit SHA as `RELEASE_SHA`. Every later step looks for that SHA, not for "the
   newest".

**No release pull request within the timeout: check whether the merge produced a workflow run at all.** A dropped
push event leaves the merge on the default branch with no run and no failure anywhere, so nothing retries.

```bash
MERGE_SHA=$(gh pr view <pr> --repo <owner>/<repo> --json mergeCommit --jq .mergeCommit.oid)
gh api "repos/<owner>/<repo>/actions/runs?event=push&head_sha=$MERGE_SHA" \
  --jq '.workflow_runs[] | "\(.id) \(.status)/\(.conclusion)"'
# empty output: no run exists for this commit, the event was lost
```

Filter by the merge SHA on the server. A client-side filter over the first page of runs reports "lost" whenever
other merges pushed the run off that page.

Recovery: re-run only the release job of an older successful run on the default branch: `gh run rerun --job <id>`.
release-please reads the branch through the API, so the run's old SHA does not matter. Choose a run whose release
step created nothing, such as a feature merge. Never re-run the run of a release pull request merge: its
`release_created` is true, so tagging and publishing would act on that run's old commit.

## Step 3: deploy

Deploy only the selected repositories, each by its host:

| Host | Reference |
|---|---|
| Heroku pipelines | [`references/heroku.md`](references/heroku.md) and [`scripts/heroku-lib.sh`](scripts/heroku-lib.sh) |
| Clever Cloud | [`references/clever-cloud.md`](references/clever-cloud.md) |
| Container-image functions behind Terraform/Terragrunt | [`references/container-functions.md`](references/container-functions.md) |

Rules that hold on every host:

- Build from the remote branch, never from a working directory. Local files end up in the artefact.
- Pre-production first. Production gets the artefact that pre-production already ran (promotion), or, where it
  cannot be promoted, the same commit.
- Gate on the identity of your release (`RELEASE_SHA`, its version, its image tag), never on the newest release.
  Configuration changes create releases too.
- Check credentials before the first long poll, and never discard stderr in an authenticated poll. An expired token
  then looks like "not ready yet" until the timeout.

Shell helpers with positional parameters live in `scripts/`, never in this file. Claude Code replaces a dollar sign
followed by a digit in `SKILL.md` with an invocation argument, so a helper written here would load as
`local app="api" branch="4.12.0"`. Source the helper file in the same shell call that uses it: each call starts a new
shell.

## Step 4: verify

Prove that every deployed app or function runs the new library, then report the evidence: which identity, where,
and when. The host references give the exact gates. In short:

- the release carrying your commit exists, and every instance runs its artefact;
- the service answers with a code the inventory lists as healthy;
- a one-off process loads the new library version from the deployed artefact;
- processes that fail after start-up (daemons, consumers) are checked again 2-3 minutes later.

If a gate fails, stop. Do not promote and do not clean up. Collect the last releases and the last 100 log lines of
the failing app and bring them to the user. After a library bump the usual causes are a new required environment
variable, an unapplied migration, or a start-up check that meets a new invariant.

## Checklist before cleanup

- [ ] The manifest pins the exact version, and the lockfile resolved it.
- [ ] The build passed. Only the manifest, the lockfile and any approved build fixes were committed.
- [ ] The pull request and its release pull request were merged, and the release contains the bump.
- [ ] Every deployed target runs the artefact of `RELEASE_SHA`.
- [ ] Pre-production was verified before production, and every production target was verified after.
- [ ] Any instance scaled up for a gate was scaled back to what it was before.

If an item fails, stop and tell the user before cleaning up.

## Step 5: cleanup

Delete the local branches (`git checkout <default> && git branch -D <branch>`). If you keep a map of which consumer
pins which version, update it in the same session.

## Notes

- **One agent per repository.** Before resuming a paused rollout agent, check who else works on that repository.
  A resumed agent runs alongside whatever is already there. Two agents on one repository once promoted production
  twice within minutes, the first time before pre-production was verified. To the second agent, the first one's
  traces looked like an outside actor.
- `gh pr merge` can answer `502 Bad Gateway` and still merge. Read the state again before retrying.
