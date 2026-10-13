---
name: gate-a-deploy
description: Gate a release and a deploy on evidence that your change is what is running. Use when releasing a package, deploying a service or promoting a build between environments, and before reporting that a deploy is done.
---

# Gate a deploy on evidence

Works with: Claude Code (distilled from release and deploy skills in daily use there; this skill form loads);
OpenCode (loads from `~/.agents/skills` in v2.0.26); Gemini CLI, DeepSeek Harness (format-compatible, untested).

A pipeline that finished green proves that something was built. These gates prove that your change is what serves
traffic. Each exists because skipping it once reported success for a deploy that had not happened.

## Before you start

- **Check credentials** for every system you will poll (CI, registry, platform) before the first long wait, and
  keep the stderr of every authenticated call: an expired token looks like "not ready yet" forever.
- **Name the artefact by your commit:** its SHA, and the version, image tag or build id it produces. Every later
  gate looks for that identity, never for "the newest".

## Release

1. Wait for the CI run of your commit (query runs by head SHA), not the latest run on the branch; someone else's
   push can finish first.
2. If no run appears for your SHA, the push event may have been lost: re-trigger that run instead of waiting.
3. Confirm the published artefact exists (the version in the registry, the tag in the image repository) before
   anything consumes it.

## Deploy

4. Promote the artefact you verified; do not rebuild it for the next environment, because a rebuild is a
   different artefact. The exception is an artefact that bakes environment settings in at build time, such as a
   typical single-page frontend: promoting it ships the source environment's settings, so build each environment
   from the same commit and verify each one.
5. Never build from a local working directory: files that were never committed end up in the deploy.
6. With infrastructure as code, require the plan to show only the change you expect and stop on anything else.
   Look for a second deploy path (a console, a script, an auto-deploy) that bypasses it.
7. Deploy one system at a time, and pass every gate before the next.

## Verify

8. Gate on the release that carries your commit, not on the newest release: configuration changes create releases
   too.
9. Check that every instance runs it. A zero-downtime cutover keeps old instances serving for a while, so an early
   probe can answer from either version; treat the first result as provisional.
10. Check HTTP status codes explicitly (`curl -sS` exits 0 on a 500), and decide in advance which codes count as
    healthy: an API without a root route may answer 404 and be fine.
11. Prove the running artefact by loading it in a one-off process on the platform and inspecting something only the
    new code has: a new export, a changed signature, a new enum value. For a frontend, fetch the served bundle
    through the real hostname and find a new member name in it.
12. Report the evidence, not the pipeline status: which identity you saw, where, and when.
