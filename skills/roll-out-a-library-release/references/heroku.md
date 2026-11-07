# Heroku pipelines

Helpers: [`../scripts/heroku-lib.sh`](../scripts/heroku-lib.sh). Source it in the same shell call that uses a
helper. In Claude Code the default install path is:

```bash
. ~/.claude/skills/roll-out-a-library-release/scripts/heroku-lib.sh
```

## Three deploy shapes

Every app linked to GitHub builds from a clean checkout of a branch, as the dashboard's **Deploy Branch** button
does. Production does not build: `pipelines:promote` moves the slug that pre-production already ran. Read each
app's shape on the dashboard's **Deploy** tab (connected repository, automatic deploys on or off) and record it in
the inventory.

**Shape 1: `auto_deploy: true`.** A merge to the default branch deploys by itself. Wait for a release that reads
`Deploy <short RELEASE_SHA>`. That is usually the release pull request's merge, not the feature merge: the two land
seconds apart, and gating on the wrong one passes on the wrong slug.

**Shape 2: `auto_deploy: false`, linked to GitHub, not production.** Trigger the branch deploy:

```bash
heroku_deploy_branch <app> <default-branch> \
  || { echo "deploy was NOT triggered, do not wait for a release" >&2; exit 1; }
```

The helper sends the same request as the button. It has no public CLI command, so set `HEROKU_BRANCH_DEPLOY_URL`
once: click **Deploy Branch** with the browser's network tab open, copy the POST request's URL, and replace the app
id in it with `{app_id}`. The helper authenticates with `heroku auth:token`.

It checks the HTTP status itself. `curl -sS` exits 0 on 401 and 5xx, so without that check an expired token looks
like a triggered deploy, and you wait the full poll for a build that does not exist.

**Shape 3: production in a pipeline.** `heroku pipelines:promote -a <pre-production app>`. It ships the slug that
was verified, and it fans out to every app in the next stage. Production apps are often linked to GitHub too, so a
shape 2 call would work there. Never use it: it builds a new slug that nobody has verified, and the new slug can
differ through dependency resolution or a flaky build.

Exceptions belong in the inventory:

- **A pipeline without a staging stage.** A promote from a `development` app looks for `staging` and fails with
  `there are no downstream apps in staging stage`. Name the targets: `--to app-a,app-b`. If a bare promote
  suddenly succeeds, someone changed the stages. Check them before you drop `--to`.
- **A pipeline with no pre-production stage at all.** Production is deployed from the branch (shape 2), and that is
  the only case where it is.
- **An app with no GitHub link.** Shape 2 is impossible: promote into it.

## Waiting for the release

Watch releases, not builds:

```bash
heroku releases -a <app> --num 10 | grep "<short RELEASE_SHA>"
```

Grep for the SHA instead of reading the top row: a `heroku config:set` can create a release above it. Do not parse
`heroku builds --json`. Its errors are easy to swallow, so the poll keeps going after the build has finished, and in a
non-interactive shell the command can start a browser login and hang.

**A promotion keeps the source release's description**, so `Deploy <sha>` finds the promoted release in production
too. Use the same SHA for pre-production and for every production app.

## Never `heroku builds:create`

It uploads a local directory as the slug source. That fails in three ways:

1. It ships your local `node_modules`, the build installs on top, and a transitive package can end up without its
   built files. The app then crash-loops at runtime on `MODULE_NOT_FOUND`, an error no local build shows.
2. Node's built-in tar can fail on large repositories. The usual workaround, `--tar gtar`, puts `node_modules` back
   in the upload.
3. In a non-interactive shell it can try a browser login and hang.

## Health gate

```bash
. ~/.claude/skills/roll-out-a-library-release/scripts/heroku-lib.sh
SHA=<short RELEASE_SHA>
deploy_health_check <staging-app> "<staging-url>" "$SHA"
# after the promote, every production app in the pipeline, in parallel:
deploy_health_check <prod-app-a> "<url-a>" "$SHA" & deploy_health_check <prod-app-b> "<url-b>" "$SHA" & wait
```

`deploy_health_check` finds the release whose description carries the SHA, then every release built from the same
slug. It waits until every web dyno is `up` on one of those releases, then retries the URL until it answers 1xx-4xx.
It fails at a deadline of 180 seconds by default (`ROLLOUT_TIMEOUT`).

Why it works this way:

- **Slug, not release number.** `config:set` creates a release on the same slug, which must pass. A newer deploy by
  someone else has a different slug, which must not pass. "Release >= target" would accept a crash-looping target with
  someone else's healthy deploy on top.
- **Every web dyno, not any.** With preboot, `heroku ps --json` lists old and new dynos together, and the router can
  still answer from the old slug. Each dyno's release is the nested `release.version` object; there is no flat
  field. A curl right after a deploy on a preboot app often answers from the old release.
- **The URL is retried.** `heroku ps` can show `up` a few seconds before the process listens. A single curl then
  gets `000` and fails a healthy boot.
- **4xx counts as healthy.** An authenticated console answers 401, and an API without a root route answers 404. List
  the expected code per app in the inventory and fail only on 5xx or a timeout.

Prove the artefact as well as the dyno. A one-off dyno that loads the library from the deployed slug proves what
the build exit code cannot:

```bash
heroku run --no-tty -a <app> 'node -e "console.log(require(\"<package>/package.json\").version)"'
```

Leave out `--size` on Basic and Eco apps: a Standard size is rejected with `invalid_params`.

**Framework start-up lines can be absent by design.** A production log level often suppresses the info-level "server
started" line, so its absence proves nothing. Take boot evidence from the platform instead: the dyno's
`State changed from starting to up`, or a log line written while the app served a real request.

## Pre-production that is not running

`No dynos` does not mean the deploy failed. Look first:

```bash
heroku ps:scale -a <app>   # "web=0:Basic" means switched off
heroku ps -a <app>
```

- **Asleep (Eco, formation at least 1):** one request wakes it. Curl the URL, then run the gate.
- **Switched off (`web=0`):** a request cannot start it. Scale up for the gate, wait for the dyno's own start-up
  line, run the real gate, and restore the formation whatever the result:

```bash
. ~/.claude/skills/roll-out-a-library-release/scripts/heroku-lib.sh
SHA=<short RELEASE_SHA>             # set it in this call: an empty SHA aborts before the restore
T0=$(date -u +%Y-%m-%dT%H:%M:%S)    # UTC, taken before the scale
heroku ps:scale web=1 -a <app>
wait_dyno_up <app> "$T0" && deploy_health_check <app> "<url>" "$SHA"; rc=$?
heroku ps:scale web=0 -a <app>      # restore before judging, or a failed gate leaves a paid dyno running
[ "$rc" -eq 0 ] || { echo "<app>: did not come up on our slug" >&2; exit 1; }
```

Do not write a "wait and curl" by hand. It passes on any dyno that happens to be up, including one on someone
else's newer release.

**A pre-production app that carries production credentials must never be scaled up.** A running dyno there would
be a second consumer of production queues and change streams. Gate it with a one-off dyno that loads the changed
module. Never load the process entry point: that starts the daemon.

```bash
heroku run --no-tty -a <app> 'node -e "console.log(require(\"<package>/package.json\").version); require(\"<changed module>\")"'
```

**Basic and Eco allow one dyno per process type.** Scaling any type to 2 moves every process type to Standard-1X. To
revert, scale the type back to 1 first, then run `heroku ps:type basic`.

## Apps without a web process

Daemons and workers have nothing to curl. Gate on `heroku ps -a <app>`: every process type must reach `up`. Read
the boot line with `heroku logs -a <app> --dyno <type>`. Always pass `-a`. Without it the CLI infers the app from a
git remote, which can point to another environment.

**Check again after 2-3 minutes.** Some processes report `up`, log a successful start, and exit 30 seconds later.
One example is a child process whose readiness handshake comes after initialisation: a failed start shows only as
the parent's timeout. A check right after the release passes, and the promote that follows ships the broken release.
Count crash lines in a later window:

```bash
heroku logs -a <app> -n 1500 | grep -cE 'crashed|MODULE_NOT_FOUND|TypeError'
```

**A new process type in the `Procfile` starts at 0 dynos.** Scale it up after the deploy, then confirm it booted.
Set the environment it needs before that.

**A promotion does not change a one-off dyno that is already running.** It swaps the slug only for dynos started
after it. A task that was running during the promote keeps producing the errors you just fixed, and its log lines
come from `run.N` rather than the process type. That is how you tell "the fix did not ship" from "the fix shipped and
an old run is still finishing". Decide whether to let it finish or stop it. `heroku ps:stop` sends SIGTERM.

**A production app that is rarely promoted can be weeks behind.** Read its last release before promoting, and
report the jump.

## Traps

- Legacy deploy scripts in a repository (`git push -f` to a Heroku remote from a local branch) predate the
  pipeline. Never run them: they ship local state. A `git push heroku-<env>` recipe has the same problem.
- `heroku logs --tail` never exits, and macOS has no `timeout` command. Read a bounded window with
  `heroku logs -a <app> -n 1500` and repeat it.
- A frontend that compiles environment settings into its bundle must not be promoted: the promoted slug points at
  the source environment. Build each environment from the same commit.
