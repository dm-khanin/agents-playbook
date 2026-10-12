# Decisions

Short records of the choices that shape this repository: the context, what was decided, and what follows from
it. New records are appended; a reversed decision gets a new record that names the one it replaces.

## D1. Catalog, not sync

**Context.** The rules and tools here grew inside live agent setups on working machines.
**Decision.** The repository is a curated catalog. Live setups stay where they are, and content enters only by an
explicit request, reviewed like any other change.
**Consequences.** Nothing installs a whole setup from the repository. The README installs chosen items on a new
machine, and drift between a live setup and the catalog is expected.

## D2. No adapter layer

**Context.** Four harnesses read customisation in different places and formats.
**Decision.** Use the formats they share (Agent Skills, `AGENTS.md`) and give each item ready-made snippets for
what they do not share (MCP configuration, hooks). No generator, no per-harness build.
**Consequences.** Supporting another harness costs README lines, not code. Snippets for a harness that was not
tested are labelled as such.

## D3. `~/.agents` is the shared install root

**Context.** Gemini CLI, OpenCode and DeepSeek Harness all read skills from `~/.agents/skills`, and DeepSeek Harness
reads `~/.agents/AGENTS.md`.
**Decision.** Install instructions target `~/.agents`; hooks and tools are copied to `~/.agents/hooks` and
`~/.agents/tools`, which is where the shipped `hooks.json` snippets point.
**Consequences.** Claude Code is the exception and gets its own paths (`~/.claude/skills`, an import line in
`~/.claude/CLAUDE.md`).

## D4. Commands are skills

**Context.** DeepSeek Harness has no file-based commands and Gemini CLI's are TOML, while every harness can invoke
a skill by name.
**Decision.** Anything that would be a slash command is written as a user-invocable skill.
**Consequences.** One file serves every harness; a harness-specific command file is never needed.

## D5. Hooks use the Claude Code format

**Context.** Claude Code reads it natively, DeepSeek Harness through its Claude Code hook bridge, and Gemini CLI's
format differs mostly in event names. OpenCode has only JavaScript plugins.
**Decision.** Ship a script plus a Claude Code `hooks.json` snippet; each README states which harnesses were
actually used.
**Consequences.** OpenCode support needs a plugin, written only when someone needs it.

## D6. The private denylist never enters the repository

**Context.** A public repository must not name the private systems and organisations its content was learned in,
and a list of those names would disclose exactly that.
**Decision.** Built-in public patterns live in the scanner. Private patterns live in a git-ignored
`.leakguard.local` and in a CI secret, and a match is reported only by the pattern's position, never by the
matched text, because a public repository's CI logs are public. CI fails when the secret is missing.
**Consequences.** Pull requests from forks receive no secrets, so their leak-scan job fails by design: outside
contributions cannot bypass the private check.

## D7. Local hooks are the last gate; CI is the backstop

**Context.** A push to a public repository publishes its content at once, before any CI result, and git hooks do
not travel with a clone.
**Decision.** Three local hooks, enabled once per clone: pre-commit scans staged files, commit-msg scans the
message, and pre-push scans the whole history with private patterns required, which makes it the last gate before
publication. CI repeats the tree and history scans, adds gitleaks, and runs on every push to any branch and on
every pull request, for clones that never enabled the hooks.
**Consequences.** A clone without the hooks can still publish a leak, and CI can then only report it; the fix is a
history rewrite. The one-time setup in `AGENTS.md` is therefore a precondition for pushing.

## D8. Global rules are short directives

**Context.** Long, README-style instruction files measurably cost agents tokens and accuracy; short, specific
directives help.
**Decision.** Each rule in `global/AGENTS.md` is a directive, the reason for it, and how to apply it, in about five
lines.
**Consequences.** Background and war stories stay out of the rules file.
