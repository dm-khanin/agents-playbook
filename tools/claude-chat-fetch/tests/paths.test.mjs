import { test } from 'node:test';
import assert from 'node:assert/strict';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { sessionPath, cacheDir } from '../lib/paths.mjs';

test('explicit variables win', () => {
  assert.equal(sessionPath({ CLAUDE_CHAT_FETCH_SESSION: '/s' }), '/s');
  assert.equal(cacheDir({ CLAUDE_CHAT_FETCH_CACHE: '/c' }), '/c');
});

test('XDG bases are honoured', () => {
  assert.equal(sessionPath({ XDG_CONFIG_HOME: '/cfg' }), join('/cfg', 'claude-chat-fetch', 'session'));
  assert.equal(cacheDir({ XDG_CACHE_HOME: '/cache' }), join('/cache', 'claude-chat-fetch'));
});

test('defaults live outside the tool directory', () => {
  assert.equal(sessionPath({}), join(homedir(), '.config', 'claude-chat-fetch', 'session'));
  assert.equal(cacheDir({}), join(homedir(), '.cache', 'claude-chat-fetch'));
});
