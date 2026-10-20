/**
 * Shared by the hooks that react to a `git push`: finds the git command in a shell line and the
 * repository it ran in.
 *
 * A push counts only when `push` is the git subcommand, so `push` inside a commit message, a log
 * search or an echoed string is ignored. Chained lines (`git commit -m x && git push`) and git-level
 * flags (`git -C <dir> push`, `git -c key=value push`) are understood.
 */

const path = require('path');

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

// Shell control operators that start a new command. Splitting on them is approximate (it ignores
// quoting), which errs towards silence: a fragment from inside a quoted string rarely starts with `git`.
const COMMAND_SEPARATOR = /&&|\|\||;|\||\n/;

// Returns the arguments after `git` for the git command in a shell line, preferring a `push` when the
// line chains several commands (`git commit -m x && git push`). Null when no command starts with `git`.
function tokenizeGitArgs(command) {
  const gitCommands = command
    .split(COMMAND_SEPARATOR)
    .map((segment) => segment.trim().split(/\s+/))
    .filter((tokens) => tokens[0] === 'git' && tokens.length > 1)
    .map((tokens) => tokens.slice(1));
  if (gitCommands.length === 0) return null;
  return gitCommands.find((tokens) => findSubcommand(tokens) === 'push') || gitCommands[0];
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

// The git arguments of the push in a shell line, or null when the line has no git push.
function pushTokens(command) {
  const tokens = tokenizeGitArgs(command);
  return tokens && findSubcommand(tokens) === 'push' ? tokens : null;
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

module.exports = { tokenizeGitArgs, findSubcommand, pushTokens, resolveRepoDir };
