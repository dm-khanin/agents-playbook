# Container-image functions behind Terraform or Terragrunt

The shape: each function's repository runs CI on the default branch, release-please cuts a version, and the
release run builds a container image tagged `v<version>` into a registry. An infrastructure repository pins
`image_version` per function and environment, and a plan and apply move the function to the new image.
The commands below use AWS (ECR, Lambda); the gates carry over to other clouds.

## Preflight

Check credentials before any registry or IaC step: `aws sts get-caller-identity`. Single sign-on tokens expire
often, and the agent cannot run the browser login. Ask the user to run `aws sso login --profile <profile>`, and wait
until it reports success. Never send the stderr of an authenticated poll to `/dev/null`: an expired token then looks
like "the image is not there yet" until the timeout.

## Wait for the image of your release

Two CI runs land on the default branch back to back, one for the feature merge and one for the release merge. A
poll of the newest run often catches the first one, and the apply then fails with `Source image v<version> does
not exist`. Poll the run of `RELEASE_SHA`:

```bash
until s=$(gh run list --repo <owner>/<repo> --workflow '<ci workflow>' \
  --json status,conclusion,headSha \
  --jq ".[] | select(.headSha==\"$RELEASE_SHA\") | \"\(.status)/\(.conclusion)\"") \
  && echo "$s" | grep -q '^completed/'; do sleep 30; done
```

`gh run list --commit` needs the full SHA; a short one returns nothing, silently. Require `completed/success`.

The registry trails CI by about half a minute. Poll the tag itself before the apply, and let auth errors through:

```bash
for i in $(seq 1 18); do
  out=$(aws ecr describe-images --repository-name <image repo> \
    --image-ids imageTag=v<version> 2>&1)
  echo "$out" | grep -q imageDigest && break
  echo "$out" | grep -qi 'token has expired' && { echo 'credentials expired: ask for a login' >&2; break; }
  sleep 10
done
```

## Deploy through the IaC repository

1. Set `image_version = "v<version>"` in the function's dev unit.
2. Run `terragrunt plan` in that unit. The plan must show only the image change. Anything else, such as IAM policy,
   environment variables or resource replacement, means the unit has drifted: stop and ask.
3. Run `terragrunt apply`, then verify (below).
4. Repeat for prod. A function with no dev unit is production-only: deploy it to prod alone, and confirm that by the
   missing dev directory, not by memory. Leave units that the inventory marks as never deployed (a sandbox, for
   example) alone, and do not ask about them each time.
5. Commit every changed config file **and every `.terraform.lock.hcl` the plan or apply wrote** on one branch, in one
   pull request. Forgotten lock files mean extra pull requests later.

`Backend configuration changed` on a plan usually means the unit's local cache predates a backend refactor. When the
bucket, key and region are unchanged, `terragrunt init -reconfigure` fixes it. Never use `-migrate-state` for that.

## Verify

- Read the deployed function's image URI and compare it with the tag you set.
- Smoke-test a queue consumer with an empty batch. It runs initialisation on the real runtime and touches no data:

  ```bash
  aws lambda invoke --function-name <dev function> --cli-binary-format raw-in-base64-out \
    --payload '{"Records":[]}' --log-type Tail out.json
  ```

  A consumer that reports partial failures should return `{"batchItemFailures":[]}`. The first cold start after an
  image change is slow, often two to three times the steady start-up, and can hit an initialisation timeout once.
  Three parallel invocations force new environments and give a steady measurement.
- A function that gets no traffic in dev needs a synthetic event pair that changes something and changes it back,
  checked against the store it writes to. A quiet log there proves nothing.
- Some cloud SDKs log a runtime deprecation warning at ERROR level on every cold start. Exclude it when you count
  errors.

## Traps

- **A second deploy path.** A CI job such as "roll out the `latest` tag to prod", gated on a repository variable or
  run by hand, bypasses the IaC pin and the dev stage. Find out whether one exists and keep it off. If a function
  ever drifts from its `image_version`, look there first.
- **Cold multi-architecture builds can hang under emulation.** An arm64 image built under QEMU can stop with
  `uncaught target signal 4 (Illegal instruction)` during dependency installation, and the job then sits silent.
  Dockerfiles with two parallel install stages hit it more often. Cancel a push job that runs longer than three
  times its usual duration, and re-run only that job (`gh run rerun <run> --job <id>`). The job log becomes readable
  only after the job ends.
- **A transient clone failure inside the image build** (exit 128 on a private dependency) comes from the git host,
  not from the bump: `gh run rerun <run> --failed`.
- **Functions missing from the inventory.** A group alias such as `all` skips them silently. A function whose pin
  is far behind, or across a major version of the library, needs the library's breaking changes read first: it is
  not a routine bump.
- If a workflow has no `workflow_dispatch` and the push event of a merge was lost, use the release-job re-run recipe
  in the main skill. Never push to the default branch.
