import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseChatUrl } from '../lib/url.mjs';

test('parseChatUrl extracts UUID from valid URL', () => {
  const uuid = parseChatUrl('https://claude.ai/chat/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');
  assert.equal(uuid, 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');
});

test('parseChatUrl throws on non-claude.ai URL', () => {
  assert.throws(
    () => parseChatUrl('https://example.com/chat/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'),
    err => err.exitCode === 2 && /not a claude\.ai chat URL/.test(err.message),
  );
});

test('parseChatUrl throws on share URL (not supported)', () => {
  assert.throws(
    () => parseChatUrl('https://claude.ai/share/abc-def'),
    err => err.exitCode === 2,
  );
});

test('parseChatUrl throws on malformed UUID', () => {
  assert.throws(
    () => parseChatUrl('https://claude.ai/chat/not-a-uuid'),
    err => err.exitCode === 2,
  );
});

test('parseChatUrl tolerates trailing slash and query string', () => {
  const uuid = parseChatUrl('https://claude.ai/chat/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee/?foo=bar');
  assert.equal(uuid, 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');
});
