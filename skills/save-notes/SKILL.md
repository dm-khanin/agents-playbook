---
name: save-notes
description: Save or update a session note after meaningful work. Use when the user asks to save notes, after a successful git push in a repository with notes enabled, or at the end of a research, design or investigation session that produced no commits.
---

# Save a session note

Works with: Claude Code (used); Gemini CLI, OpenCode, DeepSeek Harness (format-compatible, untested).

A session note is a short narrative of what was done and why, kept next to the code but out of git, so the next
session (yours or another agent's) can pick up the reasoning instead of re-deriving it.

## Where notes live

- A repository opts in by containing `.agents/notes/INDEX.md`, or `.claude/notes/INDEX.md`. Use whichever exists;
  if both do, use `.agents/notes/`. The notes directory must be listed in the repository's `.gitignore`.
- Cross-cutting notes, which belong to no single repository, go to the directory named by `$AGENT_NOTES_HOME`
  (for example a folder that holds several repositories side by side). If it is unset, ask the user where the
  note belongs.

## Which kind of note

- **Per-repository note**: the session produced committed or pushed code in one repository.
- **Cross-cutting note**: research, discussion, investigation or a decision with no committed code.
- Code committed in several repositories: one per-repository note in each.
- Nothing meaningful happened: write nothing and say so.

## Per-repository flow

1. **Precondition.** If the repository has no notes `INDEX.md`, stop and tell the user how to opt in: create
   `.agents/notes/INDEX.md` and add `.agents/notes/` to `.gitignore`. Create nothing yourself.
2. **Metadata.** Collect today's date (`YYYY-MM-DD`), the branch (`git rev-parse --abbrev-ref HEAD`), the last ten
   commits (`git log --oneline -10`), the files touched (`git diff --name-only main...HEAD`, falling back to
   `master...HEAD`) and the dominant commit type from the message prefixes (`feat`, `fix`, `refactor`, `chore`).
3. **Deduplicate.** Search the notes directory for frontmatter `branch: <current branch>`. If a note matches, was
   modified in the last seven days and covers the same task (a rebase, review fixes, a follow-up push), update it
   instead of creating another:
   - merge `commits` and `files-touched` (union, no duplicates);
   - append `### Update YYYY-MM-DD` under "What was done" with what this push changed;
   - leave "Why this approach" alone unless a decision actually changed;
   - refresh its line in `INDEX.md` only if the scope changed;
   - tell the user which note was updated, and stop.
4. **Create.** Otherwise write `YYYY-MM-DD-<slug>.md`, where the slug is kebab-case and at most five words, from
   [`references/template.md`](references/template.md). Fill every field; write `unknown` rather than guess. If the
   file name exists, append `-v2`, `-v3`. Prepend one line to `INDEX.md`:
   `- YYYY-MM-DD [type] [slug](YYYY-MM-DD-slug.md) — one-line summary`. Tell the user the path.

## Cross-cutting flow

1. Collect the date, a `type` (`research`, `discussion`, `decision` or `investigation`) and `repos-touched`, the
   repositories read during the session, which may be none.
2. Look for a note on the same topic modified in the last seven days. Same day: edit its sections in place. A later
   day: append `### Update YYYY-MM-DD`. Refresh the `INDEX.md` line only if the scope changed.
3. Otherwise create `YYYY-MM-DD-<slug>.md` with frontmatter `date`, `type`, `repos-touched`, `related`, and the
   sections `## Topic`, `## What we explored`, `## Conclusions / decisions`, `## Open questions / next steps`.
   Prepend the `INDEX.md` line as above and tell the user the path.

## Constraints

- Never `git add` or commit a note.
- "What was done" is bullets, not prose.
- Write notes in English.
