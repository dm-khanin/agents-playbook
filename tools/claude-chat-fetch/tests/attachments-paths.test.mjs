import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, sep } from 'node:path';
import { processAttachments } from '../lib/attachments.mjs';

function filesUnder(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? filesUnder(path) : [path];
  });
}

function conversationWithArtifact(id, title) {
  return {
    uuid: 'c-1', name: 'x', chat_messages: [{
      uuid: 'm1', sender: 'assistant', attachments: [], files_v2: [],
      content: [{ type: 'tool_use', name: 'artifacts',
        input: { command: 'create', id, title, type: 'text/markdown', content: 'payload' } }],
    }],
  };
}

test('an artifact id cannot steer a write outside files/', async () => {
  const root = mkdtempSync(join(tmpdir(), 'chat-fetch-paths-'));
  try {
    const cacheDir = join(root, 'cache', 'chat');
    mkdirSync(cacheDir, { recursive: true });
    const conversation = conversationWithArtifact(`x${sep}..${sep}..${sep}..${sep}..${sep}ESCAPED`, '!!!');
    await processAttachments({ conversation, api: {}, orgUuid: 'ORG', cacheDir });
    const filesDir = join(cacheDir, 'files') + sep;
    const written = filesUnder(root);
    assert.ok(written.length > 0, 'the artifact is still saved');
    for (const path of written) assert.ok(path.startsWith(filesDir), `written outside files/: ${path}`);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
