#!/usr/bin/env node
/**
 * PostToolUse hook: after a successful `git push` to a branch with an open pull request, asks Copilot to
 * review the new head through copilot-review.sh and tells the agent what happened.
 *
 * Silent for anything that is not a git push, for a branch without an open non-draft pull request, and
 * for repositories in COPILOT_ON_PUSH_SKIP. A pull request that only bumps packages listed in
 * COPILOT_ON_PUSH_SKIP_BUMPS is skipped with a note, so the agent does not wait for a review.
 *
 * Right after a push GitHub can still report the previous head. copilot-review.sh would then see a head
 * Copilot already reviewed and do nothing, so the hook first waits until the pull request shows the
 * local HEAD.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { pushTokens, resolveRepoDir } = require('../lib/git-push.cjs');

const DEFAULT_TOOL = path.join(os.homedir(), '.agents', 'tools', 'copilot-review', 'copilot-review.sh');
const PR_FIELDS = 'number,state,isDraft,headRefOid,url,files';
const MANIFESTS = new Set(['package.json']);
const LOCKFILES = new Set(['package-lock.json', 'npm-shrinkwrap.json', 'pnpm-lock.yaml', 'yarn.lock']);

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

function defaultDeps() {
  return {
    env: process.env,
    run(cmd, args, cwd) {
      const result = spawnSync(cmd, args, { cwd, encoding: 'utf-8' });
      return {
        status: result.status,
        stdout: result.stdout || '',
        stderr: result.error ? result.error.message : result.stderr || '',
      };
    },
    sleep(ms) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
    },
  };
}

function listFromEnv(value) {
  return (value || '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function positiveInt(value, fallback) {
  const n = Number.parseInt(value, 10);
  return Number.isInteger(n) && n > 0 ? n : fallback;
}

// `owner/repo` matches itself and `owner/*`.
function isSkippedRepo(repo, patterns) {
  const owner = repo.split('/')[0];
  return patterns.some((pattern) => pattern === repo || pattern === `${owner}/*`);
}

function repoFromUrl(url) {
  const match = /^https:\/\/[^/]+\/([^/]+\/[^/]+)\/pull\/\d+/.exec(url || '');
  return match ? match[1] : null;
}

function isDependencyFile(filePath) {
  const name = path.posix.basename(filePath);
  return MANIFESTS.has(name) || LOCKFILES.has(name);
}

// True when the pull request changes only manifests and lockfiles, and every changed manifest line sets
// a listed package. A lockfile-only change is not a bump of a listed package, so it is reviewed.
function onlyBumps(files, diff, packages) {
  if (packages.length === 0 || files.length === 0) return false;
  if (!files.every((file) => isDependencyFile(file.path))) return false;
  let current = null;
  let manifestLines = 0;
  for (const line of diff.split('\n')) {
    const header = /^diff --git a\/\S+ b\/(\S+)/.exec(line);
    if (header) {
      current = header[1];
      continue;
    }
    if (!current || !MANIFESTS.has(path.posix.basename(current))) continue;
    if (line.startsWith('+++') || line.startsWith('---')) continue;
    if (!line.startsWith('+') && !line.startsWith('-')) continue;
    const key = /^[+-]\s*"([^"]+)"\s*:/.exec(line);
    if (!key || !packages.includes(key[1])) return false;
    manifestLines += 1;
  }
  return manifestLines > 0;
}

function viewPr(deps, dir) {
  const result = deps.run('gh', ['pr', 'view', '--json', PR_FIELDS], dir);
  if (result.status === 0) {
    try {
      return { pr: JSON.parse(result.stdout) };
    } catch {
      return { error: 'gh pr view returned output that is not JSON' };
    }
  }
  if (/no pull requests found/i.test(result.stderr)) return { none: true };
  return { error: result.stderr.trim() || `gh pr view exited ${result.status}` };
}

function handle(input, deps = defaultDeps()) {
  if (input.tool_name !== 'Bash') return null;
  const tokens = pushTokens((input.tool_input || {}).command || '');
  if (!tokens) return null;
  const cwd = input.cwd || process.cwd();
  if (!path.isAbsolute(cwd)) return null;
  const dir = resolveRepoDir(tokens, cwd);

  const head = deps.run('git', ['rev-parse', 'HEAD'], dir);
  if (head.status !== 0) return null;
  const localHead = head.stdout.trim();

  let view = viewPr(deps, dir);
  if (view.none) return null;
  if (view.error) return `copilot-on-push: could not read the pull request for this branch: ${view.error}`;
  let { pr } = view;
  if (pr.state !== 'OPEN' || pr.isDraft) return null;
  const repo = repoFromUrl(pr.url);
  if (!repo || isSkippedRepo(repo, listFromEnv(deps.env.COPILOT_ON_PUSH_SKIP))) return null;
  const ref = `${repo}#${pr.number}`;

  const tries = positiveInt(deps.env.COPILOT_ON_PUSH_WAIT_TRIES, 8);
  const interval = positiveInt(deps.env.COPILOT_ON_PUSH_WAIT_MS, 2000);
  for (let attempt = 1; pr.headRefOid !== localHead; attempt += 1) {
    if (attempt >= tries) {
      return `copilot-on-push: ${ref} still shows head ${pr.headRefOid.slice(0, 9)}, not the local ` +
        `${localHead.slice(0, 9)}, so Copilot was not asked. Run copilot-review.sh ${repo} ${pr.number} ` +
        'once GitHub has the push.';
    }
    deps.sleep(interval);
    view = viewPr(deps, dir);
    if (!view.pr) return `copilot-on-push: lost ${ref} while waiting for the push: ${view.error || 'not found'}`;
    ({ pr } = view);
  }

  const packages = listFromEnv(deps.env.COPILOT_ON_PUSH_SKIP_BUMPS);
  const files = pr.files || [];
  if (packages.length > 0 && files.length > 0 && files.every((file) => isDependencyFile(file.path))) {
    const diff = deps.run('gh', ['pr', 'diff', String(pr.number)], dir);
    if (diff.status === 0 && onlyBumps(files, diff.stdout, packages)) {
      return `copilot-on-push: skipped ${ref}: it only bumps ${packages.join(', ')}. ` +
        'Do not wait for a Copilot review.';
    }
  }

  const tool = deps.env.COPILOT_REVIEW_BIN || DEFAULT_TOOL;
  const result = deps.run(tool, [repo, String(pr.number)], dir);
  const output = [result.stdout, result.stderr].map((text) => text.trim()).filter(Boolean).join('\n');
  const status = result.status === null ? 'did not run' : `exited ${result.status}`;
  return `copilot-on-push: copilot-review.sh ${repo} ${pr.number} ${status}.\n${output}`;
}

function main() {
  let message;
  try {
    message = handle(readInput());
  } catch (error) {
    message = `copilot-on-push: hook failed: ${error.message}`;
  }
  if (message) sendContext(message);
}

module.exports = { handle, onlyBumps, isSkippedRepo, repoFromUrl, listFromEnv };
if (require.main === module) main();
