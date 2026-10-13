# Harness matrix

How four agent harnesses consume user-level customisation: skills, global instructions, hooks, commands and MCP
servers. Researched in October 2026 from each project's own documentation and source. Harnesses move fast;
re-check a detail before relying on it.

| | Claude Code | Gemini CLI | OpenCode | DeepSeek Harness (`dsh`) |
|---|---|---|---|---|
| Skills, user | `~/.claude/skills` | `~/.gemini/skills`, `~/.agents/skills` | `~/.config/opencode/skills`, `~/.claude/skills`, `~/.agents/skills` | `~/.dsh/skills`, `~/.agents/skills` |
| Skills, project | `.claude/skills` | `.gemini/skills`, `.agents/skills` | `.opencode/skills`, `.claude/skills`, `.agents/skills` | `.dsh/skills`, `.agents/skills` |
| Symlinked skills | untested | `gemini skills link` creates them | undocumented | followed (verified in source) |
| Global instructions | `~/.claude/CLAUDE.md`, `@path` imports | `~/.gemini/GEMINI.md`; name configurable via `context.fileName`; `@./path` imports | `~/.config/opencode/AGENTS.md`, falling back to `~/.claude/CLAUDE.md`; extra files via `instructions` | `~/.dsh/AGENTS.md`, `~/.agents/AGENTS.md`; no imports |
| Hooks | `hooks` in `settings.json`; JSON on stdin | `hooks` in `settings.json`; JSON on stdin; different event names | JS/TS plugins only | Claude Code `hooks.json` through an opt-in bridge, 7 events |
| Commands | `~/.claude/commands/*.md`, or skills | `~/.gemini/commands/*.toml` | `~/.config/opencode/commands/*.md` | none file-based; user-invocable skills |
| MCP config | `claude mcp add`; JSON | `mcpServers` in `settings.json` | `mcp` in `opencode.json`; `command` is one array; env key `environment` | a YAML plugin row in `cordis.patch.yml` |
| Env references in MCP config | `${VAR}` | `$VAR`, `${VAR}`, `${VAR:-default}` | `{env:VAR}` | `!!js process.env.VAR` |

The shared install root is `~/.agents`: Gemini CLI, OpenCode and DeepSeek Harness all read skills from it, and
DeepSeek Harness reads `~/.agents/AGENTS.md`. Claude Code is the exception and gets its own paths.

## Claude Code

- Personal skills in `~/.claude/skills/<name>/SKILL.md` are picked up without a restart.
- `CLAUDE.md` files can import other files with `@path`, which is how a shared `AGENTS.md` reaches Claude Code.
- Hooks receive a JSON payload on stdin; exit code 2 blocks, and a JSON object on stdout can add context or
  return a decision. Events include `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
  `PermissionRequest` and `Stop`.

## Gemini CLI

- Skill precedence, lowest to highest: built-in, extension, user, workspace. Within a tier `.agents/skills` wins
  over `.gemini/skills`. Settings `skills.enabled` and `skills.disabled` toggle individual skills.
- `GEMINI.md` is loaded from the global location, the workspace and its parents, and just in time when tools touch
  a directory. Upward search stops at `context.memoryBoundaryMarkers` (default `[".git"]`). `AGENTS.md` and
  `CLAUDE.md` load only when listed in `context.fileName`.
- Hook events: `BeforeTool`, `AfterTool`, `BeforeAgent`, `AfterAgent`, `BeforeModel`, `AfterModel`,
  `BeforeToolSelection`, `SessionStart`, `SessionEnd`, `Notification`, `PreCompress`. Exit 0 means stdout is parsed
  as JSON, exit 2 blocks with stderr as the reason; `hookSpecificOutput.additionalContext` injects context.
- MCP: inherited environment variables that look secret are not passed to stdio servers unless listed in `env`.
  Tools appear as `mcp_<alias>_<tool>`, so avoid underscores in aliases.
- Commands are TOML (`prompt`, `description`) with `{{args}}`, `!{shell}` and `@{file}` placeholders.

## OpenCode

- Skill `name` is 1-64 lowercase characters with hyphens and must equal the directory name. Optional frontmatter:
  `license`, `compatibility`, `metadata`.
- Checked on v2.0.26: a skill copied to `~/.agents/skills` is discovered and loads with no configuration.
- v2 always reads `.claude/skills`. The v1 switches `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS` and
  `OPENCODE_DISABLE_CLAUDE_CODE` are absent from the v2.0.26 binary.
- The `skill` permission decides what the model is offered. A `deny` for `*` followed by allows for chosen names
  keeps unwanted skills out, and also hides every skill installed later until it is allowed by name.
- `AGENTS.md` has no import syntax; extra instruction files go in the `instructions` array (paths, globs, URLs).
- No shell hooks. Plugins in `~/.config/opencode/plugins/` export functions that receive
  `{project, client, $, directory, worktree}`; throwing in `tool.execute.before` blocks a tool call.
- Commands are Markdown with `$ARGUMENTS`, `$1`, `` !`cmd` `` and `@file`.

## DeepSeek Harness

- Home `~/.dsh` (override `$DSH_HOME`), shared root `~/.agents` (override `$DSH_AGENTS_HOME`).
- Skills: `<name>/SKILL.md` or a flat `<name>.md`, no recursive discovery. Names are kebab-case. Optional
  frontmatter: `whenToUse`, `metadata`, `disable-model-invocation`, `user-invocable`. Skills are invocable as `/name`.
- Instructions: `AGENTS.md` and `CLAUDE.md` plus `*.local.md` overlays in the project; `@path` imports are not
  interpreted.
- Hooks: the Claude Code bridge supports `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`,
  `SubagentStart` and `SubagentStop`; not `PermissionRequest` or `Notification`. `PreToolUse` honours `deny` and
  `ask` only.
- MCP: one plugin row per server. The stdio child's environment is scrubbed of names matching
  `KEY|PASSWORD|SECRET|TOKEN`; list what a server needs explicitly.
- Configuration is composed from YAML patch files; `dsh <profile> --dump-config` shows the result.

## Sources

- Agent Skills format: https://agentskills.io
- Gemini CLI: https://github.com/google-gemini/gemini-cli/tree/main/docs — `cli/skills.md`, `cli/gemini-md.md`,
  `tools/mcp-server.md`, `hooks/reference.md`, `cli/custom-commands.md`, `reference/configuration.md`
- OpenCode: https://opencode.ai/docs/ — `skills`, `rules`, `mcp-servers`, `plugins`, `commands`, `config`
- DeepSeek Harness: https://github.com/deepseek-ai/deepseek-harness — `docs/subsystems/skills.md`,
  `packages/skill/skill-filesystem/src/index.ts`, `packages/context/agent-instructions/src/config.ts`,
  `packages/mcp/mcp-client/README.md`, `packages/experimental/hooks-claude-code/README.md`,
  `packages/util/home-paths/src/index.ts`
- Claude Code: https://code.claude.com/docs
