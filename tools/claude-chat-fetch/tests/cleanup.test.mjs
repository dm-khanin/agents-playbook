import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { listCached, cleanCache } from '../lib/cleanup.mjs';

function makeCache() {
  const root = mkdtempSync(join(tmpdir(), 'chat-tools-clean-'));
  return { root, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

function makeChat(cacheDir, uuid, { name = 'test', files = {}, ageMs = 0 } = {}) {
  const dir = join(cacheDir, uuid);
  mkdirSync(join(dir, 'files'), { recursive: true });
  writeFileSync(join(dir, 'chat.md'), `# ${name}\nsome content`);
  writeFileSync(join(dir, 'meta.json'), JSON.stringify({ uuid, name, created_at: '2026-04-01', updated_at: '2026-04-02' }));
  writeFileSync(join(dir, 'raw.json'), '{}');
  for (const [fname, content] of Object.entries(files)) {
    writeFileSync(join(dir, 'files', fname), content);
  }
  if (ageMs > 0) {
    const past = new Date(Date.now() - ageMs);
    utimesSync(dir, past, past);
  }
}

test('listCached returns empty array when cache dir is missing', () => {
  const { root, cleanup } = makeCache();
  try {
    rmSync(root, { recursive: true });
    const entries = listCached(root);
    assert.deepEqual(entries, []);
  } finally { cleanup(); }
});

test('listCached returns entry per chat with name, size, ageMs', () => {
  const { root, cleanup } = makeCache();
  try {
    makeChat(root, '11111111-2222-3333-4444-555555555555', { name: 'first', files: { 'a.txt': 'hello' } });
    makeChat(root, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', { name: 'second' });
    const entries = listCached(root);
    assert.equal(entries.length, 2);
    const first = entries.find(e => e.uuid.startsWith('11111111'));
    assert.equal(first.name, 'first');
    assert.ok(first.size > 0);
    assert.ok(first.ageMs >= 0);
  } finally { cleanup(); }
});

test('listCached tolerates entries missing meta.json (uses uuid as name)', () => {
  const { root, cleanup } = makeCache();
  try {
    mkdirSync(join(root, '11111111-2222-3333-4444-555555555555'));
    const entries = listCached(root);
    assert.equal(entries.length, 1);
    assert.equal(entries[0].name, '(no meta)');
  } finally { cleanup(); }
});

test('cleanCache --all wipes everything', () => {
  const { root, cleanup } = makeCache();
  try {
    makeChat(root, '11111111-2222-3333-4444-555555555555');
    makeChat(root, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
    const deleted = cleanCache(root, { all: true });
    assert.equal(deleted.length, 2);
    assert.equal(listCached(root).length, 0);
  } finally { cleanup(); }
});

test('cleanCache --uuid deletes only the matching chat', () => {
  const { root, cleanup } = makeCache();
  try {
    makeChat(root, '11111111-2222-3333-4444-555555555555');
    makeChat(root, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
    const deleted = cleanCache(root, { uuid: '11111111-2222-3333-4444-555555555555' });
    assert.equal(deleted.length, 1);
    assert.equal(deleted[0].uuid, '11111111-2222-3333-4444-555555555555');
    assert.ok(!existsSync(join(root, '11111111-2222-3333-4444-555555555555')));
    assert.ok(existsSync(join(root, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')));
  } finally { cleanup(); }
});

test('cleanCache --uuid for unknown id throws exit-6 error', () => {
  const { root, cleanup } = makeCache();
  try {
    makeChat(root, '11111111-2222-3333-4444-555555555555');
    assert.throws(
      () => cleanCache(root, { uuid: 'nonexistent' }),
      err => err.exitCode === 6,
    );
  } finally { cleanup(); }
});

test('cleanCache --olderThanMs deletes only entries older than threshold', () => {
  const { root, cleanup } = makeCache();
  try {
    makeChat(root, '11111111-2222-3333-4444-555555555555', { ageMs: 0 }); // fresh
    makeChat(root, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', { ageMs: 1000 * 60 * 60 * 24 * 60 }); // 60 days
    const deleted = cleanCache(root, { olderThanMs: 1000 * 60 * 60 * 24 * 30 }); // 30 days
    assert.equal(deleted.length, 1);
    assert.equal(deleted[0].uuid, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
    assert.ok(existsSync(join(root, '11111111-2222-3333-4444-555555555555')));
    assert.ok(!existsSync(join(root, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')));
  } finally { cleanup(); }
});

test('cleanCache --dryRun returns entries but does not delete', () => {
  const { root, cleanup } = makeCache();
  try {
    makeChat(root, '11111111-2222-3333-4444-555555555555');
    const result = cleanCache(root, { all: true, dryRun: true });
    assert.equal(result.length, 1);
    assert.ok(existsSync(join(root, '11111111-2222-3333-4444-555555555555')));
  } finally { cleanup(); }
});

test('cleanCache without any selector returns empty (no-op safety)', () => {
  const { root, cleanup } = makeCache();
  try {
    makeChat(root, '11111111-2222-3333-4444-555555555555');
    const result = cleanCache(root, {});
    assert.deepEqual(result, []);
    assert.ok(existsSync(join(root, '11111111-2222-3333-4444-555555555555')));
  } finally { cleanup(); }
});
