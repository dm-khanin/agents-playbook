import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadSession } from '../lib/session.mjs';

test('missing session file: the hint names the real path and the override variable', () => {
  const path = '/nonexistent-dir/claude-chat-fetch/session';
  assert.throws(() => loadSession(path), (err) => {
    assert.match(err.message, /CLAUDE_CHAT_FETCH_SESSION/);
    assert.ok(err.message.split(path).length >= 3, 'path appears in the error and in the setup commands');
    assert.doesNotMatch(err.message, /<path-to-\.session>/);
    return true;
  });
});
