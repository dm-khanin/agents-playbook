#!/usr/bin/env node
/**
 * PostToolUse hook: after a successful `git push`, remind the agent to save a session note.
 *
 * Fires only when the shell command's git subcommand is `push` (not "push" inside a log
 * message or a grep pattern) and the repository opted in to notes by containing
 * `.agents/notes/INDEX.md` or `.claude/notes/INDEX.md`. Everything else is a silent no-op.
 *
 * The repository is taken from `git -C <path>` when present, otherwise from the hook's cwd,
 * then searched upwards (at most five levels) for the notes directory, so both
 * `cd repo && git push` and `git -C repo push` from a parent folder work.
 *
 * Registered on PostToolUse, which fires for successful tool calls; failed pushes never get here.
 */

const fs = require('fs');
const path = require('path');
const { tokenizeGitArgs, findSubcommand, resolveRepoDir } = require('../lib/git-push.cjs');

function readInput() {
  try {
    return JSON.parse(fs.readFileSync(0, 'utf-8'));
  } catch {
    return {};
  }
}

function sendContext(message) {
  console.log(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PostToolUse',
        additionalContext: message,
      },
    }),
  );
}

const NOTES_DIRS = [path.join('.agents', 'notes'), path.join('.claude', 'notes')];

function findNotesRepo(startDir) {
  let dir = startDir;
  for (let i = 0; i < 5; i += 1) {
    if (NOTES_DIRS.some((d) => fs.existsSync(path.join(dir, d, 'INDEX.md')))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

function reminderFor(input) {
  if (input.tool_name !== 'Bash') return null;
  const tokens = tokenizeGitArgs((input.tool_input || {}).command || '');
  if (!tokens || findSubcommand(tokens) !== 'push') return null;
  const cwd = input.cwd || process.cwd();
  if (!path.isAbsolute(cwd)) return null;
  const repo = findNotesRepo(resolveRepoDir(tokens, cwd));
  if (!repo) return null;
  return `git push succeeded in ${repo}, which keeps session notes. Follow the save-notes skill: ` +
    'update the existing note for this branch if one was touched in the last 7 days, otherwise create one. ' +
    'Notes are git-ignored; do not commit them.';
}

function main() {
  const message = reminderFor(readInput());
  if (message) sendContext(message);
}

module.exports = { tokenizeGitArgs, findSubcommand, resolveRepoDir, findNotesRepo, reminderFor };
if (require.main === module) main();
