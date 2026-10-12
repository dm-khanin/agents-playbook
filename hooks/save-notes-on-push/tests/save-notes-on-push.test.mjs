import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const hook = require('../save-notes-on-push.cjs');

function repoWithNotes(dirName = '.agents') {
  const root = mkdtempSync(join(tmpdir(), 'notes-'));
  mkdirSync(join(root, dirName, 'notes'), { recursive: true });
  writeFileSync(join(root, dirName, 'notes', 'INDEX.md'), '');
  return root;
}

test('detects push after git-level flags', () => {
  for (const cmd of ['git push', 'git -C /x push origin main', 'git -c a=b push', 'cd r && git --no-pager push']) {
    assert.equal(hook.findSubcommand(hook.tokenizeGitArgs(cmd)), 'push', cmd);
  }
});

test('ignores push that is not the git subcommand', () => {
  for (const cmd of ['git log --grep push', 'echo "git push"', 'git commit -m push', 'gh pr create']) {
    const tokens = hook.tokenizeGitArgs(cmd);
    assert.notEqual(tokens && hook.findSubcommand(tokens), 'push', cmd);
  }
});

test('finds the notes repo through -C and from a subdirectory', () => {
  const root = repoWithNotes();
  const sub = join(root, 'a', 'b');
  mkdirSync(sub, { recursive: true });
  assert.equal(hook.findNotesRepo(sub), root);
  assert.equal(hook.resolveRepoDir(hook.tokenizeGitArgs(`git -C ${root} push`), '/'), root);
});

test('accepts .claude/notes as the fallback location', () => {
  const root = repoWithNotes('.claude');
  assert.equal(hook.findNotesRepo(root), root);
});

test('a directory without INDEX.md is not opted in', () => {
  const root = mkdtempSync(join(tmpdir(), 'notes-'));
  mkdirSync(join(root, '.agents', 'notes'), { recursive: true });
  assert.equal(hook.findNotesRepo(root), null);
});

test('reminder only for a Bash git push in an opted-in repo', () => {
  const root = repoWithNotes();
  const push = { tool_name: 'Bash', tool_input: { command: 'git push' }, cwd: root };
  assert.match(hook.reminderFor(push), /save-notes/);
  assert.equal(hook.reminderFor({ ...push, tool_name: 'Edit' }), null);
  assert.equal(hook.reminderFor({ ...push, tool_input: { command: 'git status' } }), null);
  assert.equal(hook.reminderFor({ ...push, cwd: tmpdir() }), null);
});

test('a push chained after other commands still triggers the reminder', () => {
  const root = repoWithNotes();
  for (const command of [
    'git commit -m wip && git push',
    'git add a.md && git commit -m x && git push origin main',
    `cd /tmp; git -C ${root} push`,
    'git commit -m x || true; git push --force-with-lease',
  ]) {
    assert.match(hook.reminderFor({ tool_name: 'Bash', tool_input: { command }, cwd: root }) || '', /save-notes/, command);
  }
});

test('chains without a git push stay silent', () => {
  const root = repoWithNotes();
  for (const command of ['git commit -m "push later" && echo done', 'git log --grep push | head', 'echo git push']) {
    assert.equal(hook.reminderFor({ tool_name: 'Bash', tool_input: { command }, cwd: root }), null, command);
  }
});
