# agents-playbook: design

Status: v1 implemented · v2 implemented except `pg-read` and `aws-guard`, which are specified in §12 and not yet built · v3 implemented (§14) · 2026-10

## 1. Purpose

A curated, public collection of the techniques, skills and small tools I use with AI coding agents, packaged so
they can be reused on any machine and in any of the harnesses I work with.

It is a **catalog, not a sync target**. The live setup on each machine stays where it is. Content enters this repo
only when I ask an agent to add something, and every addition is reviewed like any other change.

Audience: me on a new machine, any agent asked to extend the repo, and a reader judging the work.

### Goals

- Every item works in at least one supported harness without modification, and says which.
- Nothing in the repo identifies an employer, a client, a private system, a person's private data or a credential.
- The rules for adding content live in the repo itself, so any agent in any harness can follow them.
- The repo shows its engineering judgement: decisions are written down, scripts are tested, CI is green.

### Non-goals

- Synchronising with a live setup in either direction.
- A per-harness adapter layer or code generator. A format all harnesses read is the adapter.
- A backup of any harness configuration (settings, permissions, memory).

## 2. Supported harnesses

Claude Code, Gemini CLI, OpenCode and DeepSeek Harness (`dsh`). How each consumes skills, instructions, hooks,
commands and MCP is recorded with sources in [`harness-matrix.md`](harness-matrix.md). The consequences for this
design are:

| Concern | Decision | Why |
|---|---|---|
| Skills | Agent Skills format, one directory per skill | Read natively by all four; `~/.agents/skills` covers Gemini, OpenCode and dsh, `~/.claude/skills` covers Claude Code |
| Global instructions | One `global/AGENTS.md` | dsh reads `~/.agents/AGENTS.md`, OpenCode reads `~/.config/opencode/AGENTS.md`; Claude Code and Gemini import it with `@path` |
| Slash commands | Written as user-invocable skills | dsh has no file-based commands; Gemini commands are TOML; a skill is invocable as `/name` everywhere |
| Hooks | Script plus a Claude Code `hooks.json` snippet | Claude Code native, dsh through its Claude Code hook bridge (7 events), Gemini close enough to port by hand; OpenCode needs a JS plugin and is marked unsupported until needed |
| MCP | A ready snippet per harness in the tool's README | Four incompatible formats (JSON, JSON with `command` arrays, YAML patch); four snippets are cheaper than a generator |

## 3. Layout

```
agents-playbook/
├── README.md            what is here, install on a new machine per harness
├── AGENTS.md            contract for any agent that adds to this repo
├── LICENSE              MIT, Dmitrii Khanin
├── global/AGENTS.md     portable agent operating rules
├── skills/<name>/       SKILL.md + optional scripts/, references/
├── tools/<name>/        standalone utilities: README, scripts, tests, MCP snippets
├── hooks/<name>/        hook script + hooks.json snippet + README
├── docs/                design.md, decisions.md, harness-matrix.md
├── scripts/             repo tooling: skill lint, test runner, their tests
├── .githooks/           opt-in pre-commit, commit-msg and pre-push guards
└── .github/workflows/   CI
```

There are no per-harness top-level folders. Harness-specific material lives inside the item that needs it.

## 4. Content conventions

- **English only**, in content, comments and commit messages.
- **Skills:** `name` and `description` frontmatter are required. `name` is kebab-case, 1–64 characters and equals the
  directory name; this is the strictest common rule across the four harnesses. One directory level only, because
  dsh and Gemini do not discover nested skills.
- **Every item states its support**: a "Works with" line naming the harnesses it was used with.
- **No absolute user paths.** Use `$HOME`, `~` or a documented environment variable.
- **Credentials only through environment variables, or a file only the owner can read whose path one names**,
  documented by name, never with an example value that looks real.
- **Third-party material** only with a compatible licence, kept beside it, plus a link to the upstream source.
- **Global rules stay short.** Each rule is a directive, the reason, and how to apply it, in about five lines.
  Long README-style instruction files measurably hurt agent performance, while short, specific directives help.

## 5. v1 content

| Path | Source | Work |
|---|---|---|
| `global/AGENTS.md` | my working rules | Rewrite with neutral examples: evidence before claims; verify against an outside number; a failed command is not a negative result; tests that can go red; scope discipline; authorisation tiers; batch runs need stop switches and bulk writes need owner review; delegation rules; commit hygiene |
| `skills/vet-third-party-tool` | new | Procedure for vetting a third-party tool, plugin or binary before install: what actually runs, network/exec/telemetry grep, checksum against the release digest, build features, injection surface |
| `skills/save-notes` | personal command + hook | Convert to a user-invocable skill; drop workspace-specific paths; keep the optional post-push hook as a hook item |
| `tools/obscura` | existing setup | Install guide and build-variant choice, curated font-kit script (copies, because the loader skips symlinks), MCP snippets for four harnesses, known limits |
| `tools/claude-chat-fetch` | personal tool | Fetch a claude.ai chat as Markdown. Ship only source, spec and tests; purge the cache and any fixture with real content first |
| `tools/statusline` | personal script | Claude Code status line, marked Claude Code only |
| `hooks/notify-telegram` | personal hook | Permission-request notification to Telegram; credentials from `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID`; remove the hard-coded secrets-file path |
| `docs/harness-matrix.md` | harness research, 2026-10 | Comparison of the four harnesses with sources |
| `docs/decisions.md` | this design | Short decision records, see §8 |

Out of v1: guarded read-only query wrappers for databases and a dev-only cloud CLI guard. The ideas are portable
but each is a rewrite from scratch; v2 specifies them (§12.1–§12.2) and has not built them yet.

## 6. Leak guard

The repo is public from the first commit, and a pushed secret survives in forks and caches even after removal, so
the guard is mechanical and runs before anything leaves the machine.

- **Public patterns**, committed: absolute home paths (`/Users/<x>`, `/home/<x>`, `C:\Users\<x>`), e-mail addresses other than
  GitHub noreply and `example.*`, RFC 1918 addresses (loopback is generic and allowed), and gitleaks' default
  secret rules. File names are scanned as well as content.
- **Private patterns**, never committed: employer, client and system names. The list itself would disclose what
  it protects. Locally it lives in a git-ignored `.leakguard.local`; in CI it comes from a repository secret
  `LEAKGUARD_PATTERNS`. CI fails if the secret is missing, so the private check cannot be skipped silently.
- **Commit identities.** The history scan also checks every author and committer against the private patterns, so
  a commit made with a work identity cannot slip through. Public patterns are not applied there: publishing a
  personal address is the owner's choice.
- **Nothing private is echoed.** A private finding is reported by pattern position only; a line that matches a
  private pattern prints no excerpt for any finding on it; a matching file path is shown as a hash. `--reveal`
  lifts this for local investigation and is never used in CI.
- **Where it runs:** `tools/leak-guard/leak_scan.py` scans staged files in pre-commit, the message in commit-msg and the
  whole history with private patterns required in pre-push, which is the last gate before anything is published.
  The hooks are opt-in per clone (`git config core.hooksPath .githooks`), because git does not carry hooks across
  clones; CI repeats the tree and history scans as the backstop for clones without them.
- **Intentional matches** (this document describing a pattern, the scanner's own test fixtures) are listed in a
  committed `.leakguard-allow` by path and pattern. Every entry is visible in review; a whole-file or wildcard
  exemption is not allowed.

## 7. CI

One workflow on every push and pull request:

1. `tools/leak-guard/leak_scan.py` over the tree and history, public and private patterns, plus gitleaks.
2. `scripts/skill_lint.py`: frontmatter present, `name` rules from §4, directory depth.
3. `shellcheck` on shell scripts.
4. Unit tests for `scripts/` and for each tool that has them, using the Python standard library and Node's
   built-in test runner, so CI has no dependency installs beyond what a tool already declares.
5. Planned with pg-read (§12.1): integration tests that need a real service start a throwaway one themselves and skip when its binaries are
   missing. CI puts the binaries on `PATH` and sets the tool's `*_REQUIRE_INTEGRATION` variable, so a skip there
   fails the job instead of passing silently.

Each check has a negative test: a fixture that must fail. A check that cannot go red protects nothing.

## 8. Decisions to record in `docs/decisions.md`

1. Catalog, not sync: live setups stay local; additions are explicit and reviewed.
2. No adapter layer: a shared format plus per-item snippets beats generated config for four consumers.
3. `~/.agents` as the shared install root, with Claude Code paths as the exception.
4. Commands are skills.
5. Hooks use the Claude Code format, because two harnesses read it.
6. The private denylist never enters the repo.
7. Local hooks are the last gate before publication; CI is the backstop.
8. Global rules are short directives, not prose.
9. A guard is a second layer; the boundary is a database role or a cloud account.
10. pg-read leaves write refusal to the server's read-only mode instead of a keyword list.
11. A guard has no default target.

## 9. Adding content later

`AGENTS.md` at the root is the contract an agent follows when asked to add something: where each kind of item
goes, the conventions in §4, the support line, running `tools/leak-guard/leak_scan.py` and
`scripts/skill_lint.py` before committing, and one item per commit with a Conventional Commit message. It is written so that any of the four
harnesses can follow it without other context.

## 10. Install on a new machine

The README gives, per harness, the commands to clone the repo and link or copy chosen skills, the global rules
file and hooks into place. Symlink support is verified per harness during implementation; where a loader skips
symlinks, the instruction is to copy.

## 11. Verification before the first push

- [x] `scripts/leak_scan.py` passes with the private pattern list, and fails on a planted fixture.
- [x] Manual read of every file for anything the patterns cannot know about.
- [x] Every skill loads in Claude Code and in at least one harness reading `~/.agents/skills`.
- [x] Every tool's README commands run as written on a clean shell.
- [x] CI is green on the pushed branch, including the private-pattern step.

## 12. v2 content

The second iteration adds one hook, two skills and two rules, and specifies two guards to be rewritten from
scratch, which are not built yet. The guards share
the stance of D9–D11: they sit behind a database role or a cloud account rather than replace one, they have no
default target, and pg-read leaves write refusal to the server.

| Path | Source | Work |
|---|---|---|
| `tools/pg-read` | private read-only query wrapper | Rewrite in Python around `psql`, §12.1; specified, not yet built |
| `tools/aws-guard` | private cloud CLI guard | Rewrite in Python, §12.2; specified, not yet built |
| `hooks/permission-lint` | private SessionStart linter | Take; add tests, a `hooks.json` and a README, §12.3 |
| `skills/write-reliable-hooks` | measured hook behaviour; the hook machinery of a private docs-sync system | Distil the failure modes and the kit that prevents them, §12.4 |
| `skills/gate-a-deploy` | two private release-and-deploy skills | Distil a platform-neutral checklist of release and deploy gates, §12.4 |
| `global/AGENTS.md`, rules 15–16 | the same sources | "A green build is not a deploy"; "prove no behaviour change with a fingerprint" |

Out of v2: a Slack attachment prefetch hook, which needs its credential and cache handling reworked first; Mongo,
Elasticsearch and Redis wrappers, which are tied to one data model; a post-merge follow-up queue, a large rewrite.
Later, on request.

### 12.1 `tools/pg-read` (specified, not yet built)

`pg-read --service NAME [--limit N] [--timeout SECONDS] [--unmask] [-c SQL]` runs one read statement, given with
`-c` or on stdin, and prints CSV.

- **Connection.** `--service` is required, must be a plain name (letters, digits, `_`, `.`, `-`) and names an
  entry in the libpq service file (`~/.pg_service.conf` or `$PGSERVICEFILE`); passwords stay in `~/.pgpass`.
  There is no default service.
- **One read-only transaction that never commits.** `psql -X` opens `BEGIN READ ONLY`, sets `statement_timeout`
  (`--timeout`, default 60 s, ceiling 600 s), `lock_timeout` (5 s) and `standard_conforming_strings` with
  `SET LOCAL`, so a service entry's own `options` cannot drop them, runs the statement, and always ends with
  `ROLLBACK`: a read has nothing to commit, and anything a statement still manages to change is undone.
  `PGOPTIONS` repeats the read-only default and the timeouts for the connection, and `PGAPPNAME` names it
  `pg-read`. `SELECT`, `WITH`, `VALUES` and `TABLE` statements run through a cursor and fetch `limit + 1` rows, so
  the cap never reorders a result; `EXPLAIN` and `SHOW` run directly in the same transaction.
- **The client check carries weight too.** A second statement in the same call would run in the same session,
  so the input must be exactly one statement, found by a tokenizer that follows PostgreSQL's lexical rules
  (quotes, dollar quotes, nested comments, non-ASCII identifier characters), and its first keyword must be one of
  the six above. There is no keyword denylist.
- **Row cap.** `--limit` defaults to 100, must be a positive integer and has a ceiling of 10 000. When `limit + 1`
  rows come back, the extra row is dropped and the summary says the output was truncated.
- **Masking.** Cells in columns whose name matches `PG_READ_MASK_COLUMNS` (default: e-mail, phone, password,
  secret, token, API key, IBAN, card) become `***`; an e-mail address in any other cell keeps two characters of
  its local part and its domain. `--unmask` needs `PG_READ_ALLOW_UNMASK=1` and is recorded in the audit log.
- **Audit log.** One JSON line per call, accepted or refused, in `$PG_READ_AUDIT_LOG` or
  `${XDG_STATE_HOME:-~/.local/state}/pg-read/audit.jsonl`, created with mode 0600: time, service, masked
  statement, limit, rows, truncation, duration, outcome and reason, and whether output was unmasked. Results are
  never logged. If the log cannot be written, the statement does not run.
- **Output.** CSV on stdout, quoted the way psql quotes its own CSV (NULL and an empty string both print as an
  empty cell), and a one-line summary on stderr.
- **Exit codes.** 0 success; 1 refused by pg-read; 2 usage or configuration error; 3 the statement failed on the
  server, including the server's own read-only refusal.
- **Tests.** Unit tests run against a fake `psql` that records its arguments and environment. Integration tests
  start a throwaway cluster with `initdb` on a Unix socket in a temporary directory and show that the server
  refuses a write hidden in a CTE, `SELECT … INTO`, `nextval()`, `EXPLAIN ANALYZE` of a write and a `set_config`
  of the read-only setting, even on a superuser connection; that `EXPLAIN ANALYZE` of `SELECT … INTO` leaves no
  table behind; that the timeout fires, also for a service entry with its own `options`; and that `ORDER BY`
  survives the row cap. They skip without `initdb` on `PATH` unless `PG_READ_REQUIRE_INTEGRATION=1`.

### 12.2 `tools/aws-guard` (specified, not yet built)

`aws-guard <service> <operation> [args…]` runs the AWS CLI when a call passes these checks in order, and refuses
it otherwise:

1. **Never**, whatever the target: calls that print secret material or credentials (Secrets Manager values, SSM
   parameter values, KMS decrypt, STS credential calls, ECR login, SSO role credentials, IAM access keys,
   `s3 presign`, `configure` and similar calls in other services; the list is not exhaustive), any call with
   `--endpoint-url` or `--debug`, and any call while `AWS_ENDPOINT_URL` or a service-specific
   `AWS_ENDPOINT_URL_*` is set. A flag given as an unambiguous prefix, which the AWS CLI accepts, counts as the
   full flag.
2. `lambda get-function` and `get-function-configuration` only with `--query`, because their full output includes
   the function's environment variables.
3. **Reads run anywhere**: operations named `describe-*`, `get-*`, `list-*`, `batch-get-*`, `head-*` or
   `lookup-*`, and `filter-log-events`, `tail`, `wait` and `ls`.
4. **Everything else counts as a write** and runs only when at least one argument names a dev resource and none
   names prod, by `AWS_GUARD_DEV_PATTERN` and `AWS_GUARD_PROD_PATTERN` (case-insensitive regular expressions;
   defaults match `dev` and `prod|production` as whole words), and only without `--profile`, `--cli-input-json`
   or `--cli-input-yaml`, which would move the account or the resource names out of the guard's sight.

The guard sets no profile or region. It runs `$AWS_GUARD_AWS`, or the first `aws` on `PATH` that is not itself. A
refusal prints `aws-guard: refused <service> <operation>: <reason>` and exits 1, a usage error exits 2, and
otherwise the exit code is the CLI's. Its README is to pair it with a harness rule that allows the guard and asks
before plain `aws`. Tests run against a fake `aws`.

### 12.3 `hooks/permission-lint`

A SessionStart hook that reads the user's and the project's Claude Code settings files and reports, through
`systemMessage`, only defects it can prove from the files: invalid JSON, which makes Claude Code drop the whole
file; path rules for `Write`, `NotebookEdit`, `MultiEdit` or `Glob`, which Claude Code accepts but never consults
(permissions documentation, checked against 2.1.296), with the `Edit(...)` or `Read(...)` rule to use instead;
a rule repeated within one list; and a rule in both `allow` and `deny`. It is silent when the files are clean and
never fails session start. Claude Code only. Tests cover each check, a clean file, a missing file and the
output shape.

### 12.4 Skills and rules

- **`write-reliable-hooks`**, for writing or debugging an agent hook. The measured failure modes: exit code 2 from
  a prompt hook blocks the prompt, and some interpreters (python3, dash) exit 2 when they cannot find their script; the working directory
  in a post-command payload is where the command ended; a prompt hook also fires on subagent hand-backs; a
  settings edit applies live and the next call can race it. The kit: `|| true` plus the script's own error log,
  surfaced later; a kill-switch variable; a time budget inside the hook timeout; non-interactive git and ssh; a cap
  on injected context; atomic state writes under a lock; a sentinel to prove a hook fires. Each fact names the
  version it was measured on.
- **`gate-a-deploy`**, a checklist from release to running service: wait for the CI run of your own commit, not
  the newest one; promote the artefact you verified instead of rebuilding it; confirm the running release carries
  your commit on every instance, because a zero-downtime cutover keeps the old release serving; check HTTP status
  codes explicitly; check credentials before a long poll and keep its stderr; look for a second deploy path that
  bypasses infrastructure as code; prove the artefact by loading it in a one-off process.
- **Rules 15 and 16** follow the shape in D8.

## 13. Verification before pushing v2

- [x] Every new test was watched failing before its code existed, and a mutation of each guard rule turns a test
  red.
- [ ] The pg-read integration suite passes locally and in CI, where `PG_READ_REQUIRE_INTEGRATION=1` (with pg-read).
- [x] Leak scan with the private patterns finds nothing in the tree or the history; every new file was read.
- [x] Both new skills load in Claude Code and in OpenCode.
- [x] Every new README block runs as written in an empty `HOME`.
- [x] CI is green on the pushed branch.

## 14. v3 content

The third iteration turns the leak guard into a tool any repository can install, adds a delegation skill and a
Slack prefetch hook, and hardens three existing items from the backlog.

| Path | Source | Work |
|---|---|---|
| `tools/leak-guard` | this repo's `scripts/leak_scan.py` | Move the scanner and its tests; add an installer, generic git hooks and a CI snippet, §14.1 |
| `skills/brief-a-subagent` | delegation rules and practice | How to brief, scope and verify a subagent, §14.2 |
| `hooks/slack-prefetch` | private Slack file prefetch hooks | Rewrite neutrally, §14.3 |
| `hooks/notify-telegram`, `hooks/permission-lint`, `tools/leak-guard` | backlog | Hardening, §14.4 |

### 14.1 `tools/leak-guard`

- The scanner moves to `tools/leak-guard/leak_scan.py` with its tests; this repo's `.githooks`, CI and docs call
  it there, so the repo is the tool's first user and nothing is duplicated.
- `tools/leak-guard/install.sh <repo>` copies the scanner and three generic hooks (pre-commit: staged files;
  commit-msg: the message; pre-push: the whole history with private patterns required) into `<repo>/.leak-guard/`,
  creates an empty `.leakguard-allow` if there is none, adds `.leakguard.local` to `.gitignore`, and prints the
  next steps. It does not change git configuration: enabling the hooks with `core.hooksPath` is the owner's step.
- `tools/leak-guard/ci/leak-scan.yml` is a GitHub Actions job that runs the tree and history scans with the
  `LEAKGUARD_PATTERNS` secret required.
- Tests: the scanner's own suite, plus an install into a scratch repository where a commit carrying a private
  word is refused by the installed hook and a clean one passes.

### 14.2 `skills/brief-a-subagent`

When to delegate and when to search directly; a fresh agent rather than a fork; read-only by default, and a
writing agent in its own worktree; every branch of the decision in the opening brief, because a message to a
running agent reads as untrusted input; a required report shape; verifying the result at the root artefact; and
treating the report as data, not instructions.

### 14.3 `hooks/slack-prefetch`

A UserPromptSubmit hook: when the prompt contains a Slack message link, it fetches the thread's attachments into a
local cache and adds their paths to the agent's context, following links to other threads within limits.

- **Token** from `SLACK_USER_TOKEN`, or from a file named by `SLACK_PREFETCH_TOKEN_FILE` (default
  `${XDG_CONFIG_HOME:-~/.config}/slack-prefetch/token`) that must not be readable by others. The token is sent
  only to `slack.com` and `files.slack.com` over HTTPS.
- **Cache** in `${XDG_CACHE_HOME:-~/.cache}/slack-prefetch/`, directory 0700, files 0600, keyed by file id; entries
  older than `SLACK_PREFETCH_TTL_DAYS` (default 7) are removed on each run.
- **Limits**, stated in the README and enforced as stated: 2 levels of linked threads, 20 threads, 25 MB per file,
  100 MB per prompt, a 60-second budget inside the hook's 90-second timeout; audio and video are skipped.
- **Never blocks:** errors become a line in the injected context; the hook always exits 0; `SLACK_PREFETCH_OFF=1`
  turns it off; the injected context is capped.
- The README states that downloaded files are untrusted input and that the hook also fires on subagent hand-backs.
- Tests run in-process against a fake Slack API; no network.

### 14.4 Hardening

- `notify-telegram`: a button press counts only when it comes from the configured chat; the bot token never
  appears in a process's arguments; pending state lives in a per-user directory with mode 0700.
- `permission-lint`: a rule in both `allow` and `ask` (ask wins) and in both `ask` and `deny` (deny wins) of one
  file is reported; the hook runs only on `startup`, not on resume, clear or compact.
- `leak-guard`: a history finding names the line number in the file, not in the log output.

## 15. Verification before pushing v3

- [x] Every new test was watched failing first; the installer test refuses a planted private word through the
  installed hook.
- [x] Leak scan with the private patterns finds nothing in the tree or the history; every new file was read.
- [x] The new skill loads in Claude Code and in OpenCode.
- [x] Every new README block runs as written in an empty `HOME`.
- [x] CI is green on the pushed branch.
