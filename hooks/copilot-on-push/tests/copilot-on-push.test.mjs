import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const HOOK = fileURLToPath(new URL('../copilot-on-push.cjs', import.meta.url));
const hook = require(HOOK);

const LOCAL = 'b'.repeat(40);
const OLD = 'a'.repeat(40);
const PUSH = { tool_name: 'Bash', tool_input: { command: 'git push' }, cwd: '/work/widgets' };

function prJson(overrides = {}) {
  return JSON.stringify({
    number: 42,
    state: 'OPEN',
    isDraft: false,
    headRefOid: LOCAL,
    url: 'https://github.com/acme/widgets/pull/42',
    files: [{ path: 'src/app.js', additions: 3, deletions: 1 }],
    ...overrides,
  });
}

const ok = (stdout) => ({ status: 0, stdout, stderr: '' });
const noPr = { status: 1, stdout: '', stderr: 'no pull requests found for branch "feature"' };

// A fake executor: `views` answers successive `gh pr view` calls, the last one repeating.
function fakeDeps({ env = {}, views = [ok(prJson())], diff = ok(''), tool = ok('copilot: re-requested'), head = ok(`${LOCAL}\n`) } = {}) {
  const calls = [];
  const sleeps = [];
  let viewIndex = 0;
  return {
    calls,
    sleeps,
    env,
    sleep: (ms) => sleeps.push(ms),
    run(cmd, args, cwd) {
      calls.push({ cmd, args, cwd });
      if (cmd === 'git') return head;
      if (cmd === 'gh' && args[1] === 'view') return views[Math.min(viewIndex++, views.length - 1)];
      if (cmd === 'gh' && args[1] === 'diff') return diff;
      return tool;
    },
  };
}

const toolCalls = (deps) => deps.calls.filter((c) => c.cmd !== 'git' && c.cmd !== 'gh');

const BUMP_DIFF = [
  'diff --git a/package-lock.json b/package-lock.json',
  '--- a/package-lock.json',
  '+++ b/package-lock.json',
  '-    "node_modules/some-dep": { "version": "1.0.0" }',
  '+    "node_modules/some-dep": { "version": "1.1.0" }',
  'diff --git a/package.json b/package.json',
  '--- a/package.json',
  '+++ b/package.json',
  '@@ -10,7 +10,7 @@',
  '   "dependencies": {',
  '-    "left-pad": "^1.2.0",',
  '+    "left-pad": "1.3.0",',
  '   }',
].join('\n');
const BUMP_FILES = [{ path: 'package-lock.json' }, { path: 'package.json' }];

test('isSkippedRepo matches the exact repository and an owner wildcard only', () => {
  assert.equal(hook.isSkippedRepo('acme/widgets', ['acme/widgets']), true);
  assert.equal(hook.isSkippedRepo('acme/widgets', ['acme/*']), true);
  assert.equal(hook.isSkippedRepo('acme/widgets', ['acme/gadgets', 'other/*']), false);
  assert.equal(hook.isSkippedRepo('acme/widgets', []), false);
});

test('repoFromUrl takes owner/repo from a pull request URL', () => {
  assert.equal(hook.repoFromUrl('https://github.com/acme/widgets/pull/42'), 'acme/widgets');
  assert.equal(hook.repoFromUrl('https://github.com/acme/widgets/issues/42'), null);
  assert.equal(hook.repoFromUrl(undefined), null);
});

test('onlyBumps accepts a listed package bump with any lockfile churn', () => {
  assert.equal(hook.onlyBumps(BUMP_FILES, BUMP_DIFF, ['left-pad']), true);
  const nested = BUMP_DIFF.replaceAll(' b/package.json', ' b/packages/api/package.json');
  assert.equal(hook.onlyBumps([{ path: 'packages/api/package.json' }], nested, ['left-pad']), true);
});

test('onlyBumps rejects anything beyond a listed package bump', () => {
  assert.equal(hook.onlyBumps(BUMP_FILES, BUMP_DIFF, ['right-pad']), false, 'unlisted package');
  assert.equal(hook.onlyBumps(BUMP_FILES, BUMP_DIFF, []), false, 'no packages configured');
  const withScript = BUMP_DIFF.replace('+    "left-pad": "1.3.0",', '+    "left-pad": "1.3.0",\n+    "build": "tsc",');
  assert.equal(hook.onlyBumps(BUMP_FILES, withScript, ['left-pad']), false, 'extra manifest line');
  assert.equal(hook.onlyBumps([...BUMP_FILES, { path: 'src/app.js' }], BUMP_DIFF, ['left-pad']), false, 'source file');
  const lockOnly = BUMP_DIFF.slice(0, BUMP_DIFF.indexOf('diff --git a/package.json'));
  assert.equal(hook.onlyBumps([{ path: 'package-lock.json' }], lockOnly, ['left-pad']), false, 'lockfile only');
});

test('stays silent for other tools and for commands without a git push', () => {
  for (const input of [
    { ...PUSH, tool_name: 'Edit' },
    { ...PUSH, tool_input: { command: 'git commit -m "push later"' } },
    { ...PUSH, tool_input: { command: 'echo git push' } },
  ]) {
    const deps = fakeDeps();
    assert.equal(hook.handle(input, deps), null);
    assert.deepEqual(deps.calls, []);
  }
});

test('stays silent for a dry-run push, which pushes nothing', () => {
  for (const command of ['git push --dry-run', 'git push -n origin feature', 'git -C ../x push --dry-run']) {
    const deps = fakeDeps();
    assert.equal(hook.handle({ ...PUSH, tool_input: { command } }, deps), null, command);
    assert.deepEqual(deps.calls, [], command);
  }
});

test('stays silent outside a git repository and on a branch without a pull request', () => {
  const notRepo = fakeDeps({ head: { status: 128, stdout: '', stderr: 'not a git repository' } });
  assert.equal(hook.handle(PUSH, notRepo), null);
  assert.equal(notRepo.calls.some((c) => c.cmd === 'gh'), false);

  const deps = fakeDeps({ views: [noPr] });
  assert.equal(hook.handle(PUSH, deps), null);
  assert.deepEqual(toolCalls(deps), []);
});

test('reports a gh failure that is not a missing pull request', () => {
  const deps = fakeDeps({ views: [{ status: 4, stdout: '', stderr: 'gh: authentication required' }] });
  assert.match(hook.handle(PUSH, deps), /could not read the pull request.*authentication required/);
  assert.deepEqual(toolCalls(deps), []);
});

test('stays silent for closed and draft pull requests', () => {
  for (const pr of [{ state: 'MERGED' }, { state: 'CLOSED' }, { isDraft: true }]) {
    const deps = fakeDeps({ views: [ok(prJson(pr))] });
    assert.equal(hook.handle(PUSH, deps), null, JSON.stringify(pr));
    assert.deepEqual(toolCalls(deps), []);
  }
});

test('skips repositories on the skip list', () => {
  for (const skip of ['acme/widgets', 'acme/*', 'other/x, acme/widgets']) {
    const deps = fakeDeps({ env: { COPILOT_ON_PUSH_SKIP: skip } });
    assert.equal(hook.handle(PUSH, deps), null, skip);
    assert.deepEqual(toolCalls(deps), []);
  }
  const elsewhere = fakeDeps({ env: { COPILOT_ON_PUSH_SKIP: 'acme/gadgets' } });
  assert.notEqual(hook.handle(PUSH, elsewhere), null);
  assert.equal(toolCalls(elsewhere).length, 1);
});

test('runs copilot-review.sh for the pull request once its head is the local HEAD', () => {
  const deps = fakeDeps({ env: { COPILOT_REVIEW_BIN: '/opt/copilot-review.sh' } });
  const message = hook.handle(PUSH, deps);
  assert.deepEqual(toolCalls(deps), [{ cmd: '/opt/copilot-review.sh', args: ['acme/widgets', '42'], cwd: '/work/widgets' }]);
  assert.match(message, /copilot-review\.sh acme\/widgets 42 exited 0\.\ncopilot: re-requested/);
  assert.deepEqual(deps.sleeps, []);
});

test('defaults to the installed copilot-review tool', () => {
  const deps = fakeDeps();
  hook.handle(PUSH, deps);
  assert.match(toolCalls(deps)[0].cmd, /\.agents\/tools\/copilot-review\/copilot-review\.sh$/);
});

test('uses the -C directory for git, gh and the tool', () => {
  const deps = fakeDeps();
  hook.handle({ ...PUSH, tool_input: { command: 'git -C ../gadgets push origin feature' } }, deps);
  assert.ok(deps.calls.length > 0);
  for (const call of deps.calls) assert.equal(call.cwd, '/work/gadgets', call.cmd);
});

test('waits for GitHub to show the pushed head before asking', () => {
  const deps = fakeDeps({
    env: { COPILOT_ON_PUSH_WAIT_MS: '5' },
    views: [ok(prJson({ headRefOid: OLD })), ok(prJson({ headRefOid: OLD })), ok(prJson())],
  });
  hook.handle(PUSH, deps);
  assert.deepEqual(deps.sleeps, [5, 5]);
  assert.equal(toolCalls(deps).length, 1);
});

test('gives up without asking when the head never arrives', () => {
  const deps = fakeDeps({ env: { COPILOT_ON_PUSH_WAIT_TRIES: '3' }, views: [ok(prJson({ headRefOid: OLD }))] });
  const message = hook.handle(PUSH, deps);
  assert.match(message, /still shows head aaaaaaaaa, not the local bbbbbbbbb, so Copilot was not asked/);
  assert.equal(deps.sleeps.length, 2);
  assert.deepEqual(toolCalls(deps), []);
});

test('reports a pull request lost while waiting', () => {
  const deps = fakeDeps({ views: [ok(prJson({ headRefOid: OLD })), noPr] });
  assert.match(hook.handle(PUSH, deps), /lost acme\/widgets#42 while waiting/);
  assert.deepEqual(toolCalls(deps), []);
});

test('skips a pull request that only bumps a listed package, and says so', () => {
  const deps = fakeDeps({
    env: { COPILOT_ON_PUSH_SKIP_BUMPS: 'left-pad' },
    views: [ok(prJson({ files: BUMP_FILES }))],
    diff: ok(BUMP_DIFF),
  });
  assert.match(hook.handle(PUSH, deps), /skipped acme\/widgets#42: it only bumps left-pad\. Do not wait/);
  assert.deepEqual(toolCalls(deps), []);
});

test('reviews a pull request that touches more than dependencies, without fetching its diff', () => {
  const deps = fakeDeps({ env: { COPILOT_ON_PUSH_SKIP_BUMPS: 'left-pad' } });
  hook.handle(PUSH, deps);
  assert.equal(deps.calls.some((c) => c.cmd === 'gh' && c.args[1] === 'diff'), false);
  assert.equal(toolCalls(deps).length, 1);
});

test('reviews a dependency-only pull request when its diff cannot be read', () => {
  const deps = fakeDeps({
    env: { COPILOT_ON_PUSH_SKIP_BUMPS: 'left-pad' },
    views: [ok(prJson({ files: BUMP_FILES }))],
    diff: { status: 1, stdout: '', stderr: 'boom' },
  });
  hook.handle(PUSH, deps);
  assert.equal(toolCalls(deps).length, 1);
});

test('says the tool did not run when it cannot be started', () => {
  const deps = fakeDeps({ tool: { status: null, stdout: '', stderr: 'spawnSync /x ENOENT' } });
  assert.match(hook.handle(PUSH, deps), /did not run\.\nspawnSync \/x ENOENT/);
});

test('end to end: a real repository, a fake gh and a fake tool', () => {
  const root = mkdtempSync(join(tmpdir(), 'copilot-on-push-'));
  const repo = join(root, 'repo');
  const bin = join(root, 'bin');
  mkdirSync(repo);
  mkdirSync(bin);
  const git = (...args) => execFileSync('git', ['-C', repo, ...args], { encoding: 'utf-8' });
  git('init', '-q');
  git('-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-q', '--allow-empty', '-m', 'init');
  const head = git('rev-parse', 'HEAD').trim();

  writeFileSync(join(bin, 'gh'), [
    '#!/bin/sh',
    'if [ "$1 $2" = "pr view" ]; then',
    `  printf '%s\\n' '${prJson({ headRefOid: head })}'`,
    '  exit 0',
    'fi',
    'echo "unexpected gh call: $*" >&2',
    'exit 3',
    '',
  ].join('\n'));
  writeFileSync(join(bin, 'review'), '#!/bin/sh\necho "fake-review $*"\n');
  chmodSync(join(bin, 'gh'), 0o755);
  chmodSync(join(bin, 'review'), 0o755);

  const input = JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'git push origin HEAD' }, cwd: repo });
  const result = spawnSync('node', [HOOK], {
    input,
    encoding: 'utf-8',
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, COPILOT_REVIEW_BIN: join(bin, 'review') },
  });
  assert.equal(result.status, 0, result.stderr);
  const { hookSpecificOutput } = JSON.parse(result.stdout);
  assert.equal(hookSpecificOutput.hookEventName, 'PostToolUse');
  assert.match(hookSpecificOutput.additionalContext, /exited 0\.\nfake-review acme\/widgets 42/);
});
