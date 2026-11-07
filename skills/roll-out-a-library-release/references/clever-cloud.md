# Clever Cloud

Clever Cloud deploys whatever is pushed to the app's git remote. A Heroku release list has no equivalent here, so
the `clever` CLI is the only evidence that a deploy landed.

## Setup

`npm i -g clever-tools`, then `clever login` (browser login, stored in a local profile). The agent cannot complete
the login: ask the user to run it.

## Deploy

Many repositories wrap the push in a script. Read the script before running it:

- **It probably ships your local branch, not the remote one** (`git push <remote> master:master` or
  `HEAD:master`). Pull to the release commit and confirm a clean tree first.
- **Run it from the directory it expects.** A script that does `git clone -l ../ ../build` works from `scripts/` and
  breaks from the repository root. There `../` is the parent directory, the clone fails, and a stale `../build` left
  from an earlier run is pushed instead. A `repository '../' does not exist` error is not harmless.
- Delete a leftover build directory afterwards. Test runners can pick up its copies of the tests.

## A pushed commit is not a deploy

`git ls-remote` proves only that the remote received the commit. The build and the start can still fail, and the
script may print nothing useful about it. Once, a testing app failed every deploy for three weeks while `ls-remote`
showed the right commit the whole time.

Gate on the CLI:

```bash
clever activity --app <app-id>   # one row per deploy: OK, FAIL or CANCELLED. The last row is the gate.
clever status   --app <app-id>   # "running (..., Commit: <sha>)": the commit actually running
clever logs     --app <app-id> --since <iso8601> --until <iso8601> [--search <pattern>]
clever logs     --app <app-id> --deployment-id <deployment-id> --since <iso8601> --until <iso8601>
```

Pass when the last `activity` row reads `OK` and `status` reports `running` at `RELEASE_SHA`. A `FAIL` row is a
failed deploy even when the push succeeded. A background job has no URL to curl: wait 2-3 minutes and read a log
window before judging.

## When a deploy fails

- **Look at the environment first.** An app that checks its database, cache and search connections at start-up fails
  the deploy on one stale secret, even when the code is fine. Read the deployment log before you suspect the bump.
- A database URL whose password contains `?`, `/`, `#` or `%` must percent-encode them. URL-based parsers throw on
  a raw `?`.

## CLI traps

- `clever logs` streams forever unless both `--since` and `--until` are given.
- `clever env --format json` wraps the variables in `{env, fromAddons, fromDependencies}`. Use `--format shell` to
  read them.
- `clever env set` and `clever env rm` do not restart the app. The change reaches the process at the next deploy or
  restart.
