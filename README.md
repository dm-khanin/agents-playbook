# agents-playbook

Rules, skills and small tools for working with AI coding agents, in formats that Claude Code, Gemini CLI, OpenCode
and DeepSeek Harness all read.

![ci](https://github.com/dm-khanin/agents-playbook/actions/workflows/ci.yml/badge.svg)

## Why

These are practices learned while running coding agents against real systems, kept small enough to read in one
sitting. They use the formats the harnesses already share instead of an adapter layer, so moving to another
harness costs a few install lines. The repository is public, so a leak guard checks every commit and the whole
history for anything that should not be published.

## What's inside

| Kind | Item | What it does | Works with |
|---|---|---|---|
| Rules | [`global/AGENTS.md`](global/AGENTS.md) | 16 operating rules: evidence before claims, tests that can fail, scope, authority, delegation, change hygiene, shipping | Any harness with a global instructions file |
| Skill | [`vet-third-party-tool`](skills/vet-third-party-tool/SKILL.md) | Procedure for vetting a tool, binary, plugin or skill before installing it | Claude Code, OpenCode; others format-compatible, untested |
| Skill | [`save-notes`](skills/save-notes/SKILL.md) | Keeps per-repository and cross-cutting session notes that the next session can pick up | Claude Code, OpenCode; others format-compatible, untested |
| Skill | [`write-reliable-hooks`](skills/write-reliable-hooks/SKILL.md) | Hook failure modes measured in practice, and the kit that prevents them | Claude Code, OpenCode; others format-compatible, untested |
| Skill | [`gate-a-deploy`](skills/gate-a-deploy/SKILL.md) | Release and deploy gates that prove your commit is what is running | Claude Code, OpenCode; others format-compatible, untested |
| Skill | [`brief-a-subagent`](skills/brief-a-subagent/SKILL.md) | Whether to delegate, how to scope and brief a subagent, and how to treat its report | Claude Code, OpenCode; others format-compatible, untested |
| Hook | [`save-notes-on-push`](hooks/save-notes-on-push/) | After a successful `git push`, reminds the agent to save a note | Claude Code; DeepSeek Harness via its bridge, untested |
| Hook | [`notify-telegram`](hooks/notify-telegram/) | Approve, always-allow or deny permission prompts from Telegram | Claude Code |
| Hook | [`permission-lint`](hooks/permission-lint/) | At session start, reports permission rules that are never consulted, repeated, or overridden by a stronger list | Claude Code |
| Hook | [`slack-prefetch`](hooks/slack-prefetch/) | Downloads the attachments of Slack threads linked in a prompt so the agent can read them | Claude Code; DeepSeek Harness via its bridge, untested |
| Hook | [`copilot-on-push`](hooks/copilot-on-push/) | After a push to a branch with an open pull request, asks Copilot to review the new head; skips bump-only pull requests | Claude Code; DeepSeek Harness via its bridge, untested |
| Tool | [`obscura`](tools/obscura/) | Setup guide for a light headless browser with MCP snippets for four harnesses, plus a font kit | Any MCP harness |
| Tool | [`claude-chat-fetch`](tools/claude-chat-fetch/) | Turns one of your claude.ai conversations into Markdown an agent can read | Any harness with a shell |
| Tool | [`statusline`](tools/statusline/) | Status line with branch, context use, rate limit, cost and duration | Claude Code |
| Tool | [`leak-guard`](tools/leak-guard/) | Keeps private names out of a public repository: hooks and a CI job, with a private list that never enters the repo | Any git repository |
| Tool | [`usage-guard`](tools/usage-guard/) | Pauses sessions at 97% of a claude.ai plan window and wakes them after the reset, with Telegram notices | Claude Code |
| Tool | [`copilot-review`](tools/copilot-review/) | Requests or re-requests a Copilot review on a pull request without the GitHub UI, and proves the request registered | Claude Code; any harness with a shell, untested |

## Install on a new machine

```sh
git clone https://github.com/dm-khanin/agents-playbook.git
cd agents-playbook
```

**Skills.** Copy the ones you want:

```sh
mkdir -p ~/.agents/skills ~/.claude/skills
cp -R skills/vet-third-party-tool ~/.agents/skills/   # Gemini CLI, OpenCode, DeepSeek Harness
cp -R skills/vet-third-party-tool ~/.claude/skills/   # Claude Code
```

Copying is the default. Symlinks are known to work in DeepSeek Harness, and Gemini CLI creates them itself with
`gemini skills link`; elsewhere they are untested.

**Global rules.** Put [`global/AGENTS.md`](global/AGENTS.md) where your harness reads it:

| Harness | Where |
|---|---|
| DeepSeek Harness | `~/.agents/AGENTS.md` |
| OpenCode | `~/.config/opencode/AGENTS.md` |
| Claude Code | `~/.agents/AGENTS.md`, plus the line `@~/.agents/AGENTS.md` in `~/.claude/CLAUDE.md` |
| Gemini CLI | `~/.agents/AGENTS.md`, plus an `@` import of its absolute path in `~/.gemini/GEMINI.md` |

**Hooks and tools.** Copy them to `~/.agents/hooks/` and `~/.agents/tools/`, where the shipped `hooks.json`
snippets point. The hooks that react to `git push` also need `hooks/lib/` copied next to them. Follow each
item's README for settings and MCP configuration.

## How it is kept clean

[`tools/leak-guard`](tools/leak-guard/) checks staged files, the tree and the full history, commit authors
included, against built-in public patterns and a private list that never enters the repository; CI runs it with
gitleaks, a skill linter, shellcheck and every test suite. Details in [`docs/design.md`](docs/design.md) §6.

## Design

- [`docs/design.md`](docs/design.md): goals, layout and conventions
- [`docs/decisions.md`](docs/decisions.md): why it is built this way
- [`docs/harness-matrix.md`](docs/harness-matrix.md): how each harness reads skills, rules, hooks, commands and MCP

## Contributing

Agents and humans follow [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE)
