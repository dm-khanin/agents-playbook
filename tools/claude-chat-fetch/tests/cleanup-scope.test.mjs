import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { cleanCache, listCached } from '../lib/cleanup.mjs';

test('only chat-shaped folders are listed or deleted, even with --all', () => {
  const root = mkdtempSync(join(tmpdir(), 'chat-fetch-clean-'));
  try {
    mkdirSync(join(root, '11111111-2222-3333-4444-555555555555'));
    mkdirSync(join(root, 'some-other-app'));
    writeFileSync(join(root, 'some-other-app', 'data.bin'), 'keep');
    assert.deepEqual(listCached(root).map((e) => e.uuid), ['11111111-2222-3333-4444-555555555555']);
    cleanCache(root, { all: true });
    assert.ok(existsSync(join(root, 'some-other-app', 'data.bin')), 'a foreign folder survived --all');
    assert.ok(!existsSync(join(root, '11111111-2222-3333-4444-555555555555')));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
