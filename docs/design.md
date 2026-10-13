# agents-playbook: design

Status: implemented in v1 · 2026-10

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
├── scripts/             repo tooling: leak scan, skill lint, their tests
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
- **Credentials only through environment variables**, documented by name, never with an example value that looks
  real.
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
but each is a rewrite from scratch. Later, on request.

## 6. Leak guard

The repo is public from the first commit, and a pushed secret survives in forks and caches even after removal, so
the guard is mechanical and runs before anything leaves the machine.

- **Public patterns**, committed: absolute home paths (`/Users/<x>`, `/home/<x>`, `C:\Users\<x>`), e-mail addresses other than
  GitHub noreply and `example.*`, RFC 1918 addresses (loopback is generic and allowed), and gitleaks' default
  secret rules. File names are scanned as well as content.
- **Private patterns**, never committed: employer, client and system names. The list itself would disclose what
  it protects. Locally it lives in a git-ignored `.leakguard.local`; in CI it comes from a repository secret
  `LEAKGUARD_PATTERNS`. CI fails if the secret is missing, so the private check cannot be skipped silently.
- **Nothing private is echoed.** A private finding is reported by pattern position only; a line that matches a
  private pattern prints no excerpt for any finding on it; a matching file path is shown as a hash. `--reveal`
  lifts this for local investigation and is never used in CI.
- **Where it runs:** `scripts/leak_scan.py` scans staged files in pre-commit, the message in commit-msg and the
  whole history with private patterns required in pre-push, which is the last gate before anything is published.
  The hooks are opt-in per clone (`git config core.hooksPath .githooks`), because git does not carry hooks across
  clones; CI repeats the tree and history scans as the backstop for clones without them.
- **Intentional matches** (this document describing a pattern, the scanner's own test fixtures) are listed in a
  committed `.leakguard-allow` by path and pattern. Every entry is visible in review; a whole-file or wildcard
  exemption is not allowed.

## 7. CI

One workflow on every push and pull request:

1. `scripts/leak_scan.py` over the tree and history, public and private patterns, plus gitleaks.
2. `scripts/skill_lint.py`: frontmatter present, `name` rules from §4, directory depth.
3. `shellcheck` on shell scripts.
4. Unit tests for `scripts/` and for each tool that has them, using the Python standard library and Node's
   built-in test runner, so CI has no dependency installs beyond what a tool already declares.

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

## 9. Adding content later

`AGENTS.md` at the root is the contract an agent follows when asked to add something: where each kind of item
goes, the conventions in §4, the support line, running `scripts/leak_scan.py` and `scripts/skill_lint.py` before
committing, and one item per commit with a Conventional Commit message. It is written so that any of the four
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
- [ ] CI is green on the pushed branch, including the private-pattern step.
