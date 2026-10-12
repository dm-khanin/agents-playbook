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

// Git-level flags that consume the next token as their value (skip it when
// scanning for the subcommand). Anything starting with `--` or `-X` without
// a known value requirement is assumed to be a boolean/value-attached flag
// and is skipped without consuming the next token.
const GIT_LEVEL_FLAGS_WITH_VALUE = new Set([
  '-C',
  '-c',
  '--exec-path',
  '--git-dir',
  '--work-tree',
  '--namespace',
  '--config-env',
  '--list-cmds',
]);

function tokenizeGitArgs(command) {
  const match = command.match(/(?:^|[\s;&|])git\s+(.+)$/);
  if (!match) return null;
  return match[1].trim().split(/\s+/);
}

function findSubcommand(tokens) {
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i];
    if (GIT_LEVEL_FLAGS_WITH_VALUE.has(tok)) {
      i += 1;
      continue;
    }
    if (tok.startsWith('-')) continue;
    return tok;
  }
  return null;
}

function findDashCPath(tokens) {
  for (let i = 0; i < tokens.length - 1; i += 1) {
    if (tokens[i] === '-C') return tokens[i + 1];
  }
  return null;
}

function resolveRepoDir(tokens, cwd) {
  const p = findDashCPath(tokens);
  if (p) {
    const cleaned = p.replace(/^['"]|['"]$/g, '');
    return path.isAbsolute(cleaned) ? cleaned : path.resolve(cwd, cleaned);
  }
  return cwd;
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
