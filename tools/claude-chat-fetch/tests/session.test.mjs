import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, mkdtempSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadSession, saveOrgUuid } from '../lib/session.mjs';

function makeTempSession(contents, mode = 0o600) {
  const dir = mkdtempSync(join(tmpdir(), 'chat-tools-test-'));
  const path = join(dir, '.session');
  writeFileSync(path, contents);
  chmodSync(path, mode);
  return { path, cleanup: () => rmSync(dir, { recursive: true }) };
}

test('loadSession returns sessionKey from valid file', () => {
  const { path, cleanup } = makeTempSession('sessionKey=sk-ant-sid01-abc123\n');
  try {
    const session = loadSession(path);
    assert.equal(session.sessionKey, 'sk-ant-sid01-abc123');
    assert.equal(session.orgUuid, undefined);
  } finally { cleanup(); }
});

test('loadSession returns orgUuid when present', () => {
  const contents = 'sessionKey=sk-ant-sid01-abc123\norg_uuid=11111111-2222-3333-4444-555555555555\n';
  const { path, cleanup } = makeTempSession(contents);
  try {
    const session = loadSession(path);
    assert.equal(session.orgUuid, '11111111-2222-3333-4444-555555555555');
  } finally { cleanup(); }
});

test('loadSession throws (exit 3) when file is missing', () => {
  assert.throws(
    () => loadSession('/nonexistent/.session'),
    err => err.exitCode === 3,
  );
});

test('loadSession throws (exit 3) when sessionKey missing from file', () => {
  const { path, cleanup } = makeTempSession('org_uuid=foo\n');
  try {
    assert.throws(() => loadSession(path), err => err.exitCode === 3);
  } finally { cleanup(); }
});

test('loadSession throws (exit 4) when file is group-readable', () => {
  const { path, cleanup } = makeTempSession('sessionKey=sk-ant-sid01-abc123\n', 0o640);
  try {
    assert.throws(() => loadSession(path), err => err.exitCode === 4);
  } finally { cleanup(); }
});

test('saveOrgUuid appends org_uuid without losing sessionKey', () => {
  const { path, cleanup } = makeTempSession('sessionKey=sk-ant-sid01-abc123\n');
  try {
    saveOrgUuid(path, '11111111-2222-3333-4444-555555555555');
    const session = loadSession(path);
    assert.equal(session.sessionKey, 'sk-ant-sid01-abc123');
    assert.equal(session.orgUuid, '11111111-2222-3333-4444-555555555555');
  } finally { cleanup(); }
});
