import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync, existsSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { processAttachments } from '../lib/attachments.mjs';

function loadFixture(name) {
  return JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8'));
}

function makeTempDir() {
  const dir = mkdtempSync(join(tmpdir(), 'chat-tools-attach-'));
  return { dir, cleanup: () => rmSync(dir, { recursive: true }) };
}

function fakeApi(responses) {
  return {
    async getBinary(url) {
      const buf = responses[url];
      if (!buf) throw Object.assign(new Error('not found'), { exitCode: 6 });
      return buf;
    },
    async getJson(url) {
      const data = responses[url];
      if (!data) throw Object.assign(new Error('not found'), { exitCode: 6 });
      return data;
    },
  };
}

test('processAttachments downloads each file_uuid into files/', async () => {
  const conv = loadFixture('conversation-with-files.json');
  const { dir, cleanup } = makeTempDir();
  try {
    const api = fakeApi({
      'https://claude.ai/api/ORG/files/file-aaa/contents': new Uint8Array([1,2,3]).buffer,
      'https://claude.ai/api/ORG/files/file-bbb/contents': new TextEncoder().encode('hello log').buffer,
    });
    const manifest = await processAttachments({ conversation: conv, api, orgUuid: 'ORG', cacheDir: dir });
    assert.ok(existsSync(join(dir, 'files/screenshot.png')));
    assert.ok(existsSync(join(dir, 'files/log.txt')));
    assert.equal(statSync(join(dir, 'files/screenshot.png')).size, 3);

    const msg1 = manifest.get('msg-1');
    assert.equal(msg1.attachments.length, 2);
    assert.equal(msg1.attachments[0].localPath, 'files/screenshot.png');
    assert.equal(msg1.attachments[0].kind, 'image');
  } finally { cleanup(); }
});

test('processAttachments handles individual file 404 with [file unavailable] marker', async () => {
  const conv = loadFixture('conversation-with-files.json');
  const { dir, cleanup } = makeTempDir();
  try {
    const api = {
      async getBinary(url) {
        if (url.includes('file-aaa')) throw Object.assign(new Error('404'), { exitCode: 6 });
        return new TextEncoder().encode('ok').buffer;
      },
      async getJson() { throw new Error('unused'); },
    };
    const manifest = await processAttachments({ conversation: conv, api, orgUuid: 'ORG', cacheDir: dir });
    const msg1 = manifest.get('msg-1');
    assert.equal(msg1.attachments[0].unavailable, true);
    assert.equal(msg1.attachments[1].unavailable, undefined);
  } finally { cleanup(); }
});

test('processAttachments skips files larger than 50MB with size marker', async () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    projects_v2_uuid: null,
    chat_messages: [{
      uuid: 'm1', sender: 'human',
      content: [{ type: 'text', text: 'big file' }],
      attachments: [],
      files_v2: [{ file_uuid: 'huge', file_name: 'huge.bin', file_kind: 'document', file_size: 60_000_000 }],
    }],
  };
  const { dir, cleanup } = makeTempDir();
  try {
    const api = fakeApi({});
    const manifest = await processAttachments({ conversation: conv, api, orgUuid: 'ORG', cacheDir: dir });
    const att = manifest.get('m1').attachments[0];
    assert.equal(att.tooLarge, true);
    assert.match(att.note, /too large/i);
    assert.ok(!existsSync(join(dir, 'files/huge.bin')));
  } finally { cleanup(); }
});

test('processAttachments deduplicates filename collisions with -N suffix', async () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    projects_v2_uuid: null,
    chat_messages: [{
      uuid: 'm1', sender: 'human',
      content: [{ type: 'text', text: 'two with same name' }],
      attachments: [],
      files_v2: [
        { file_uuid: 'a', file_name: 'log.txt', file_kind: 'text', file_size: 5 },
        { file_uuid: 'b', file_name: 'log.txt', file_kind: 'text', file_size: 5 },
      ],
    }],
  };
  const { dir, cleanup } = makeTempDir();
  try {
    const api = fakeApi({
      'https://claude.ai/api/ORG/files/a/contents': new TextEncoder().encode('first').buffer,
      'https://claude.ai/api/ORG/files/b/contents': new TextEncoder().encode('second').buffer,
    });
    const manifest = await processAttachments({ conversation: conv, api, orgUuid: 'ORG', cacheDir: dir });
    const paths = manifest.get('m1').attachments.map(a => a.localPath);
    assert.deepEqual(paths, ['files/log.txt', 'files/log-1.txt']);
  } finally { cleanup(); }
});

test('processAttachments saves pasted text from extracted_content', async () => {
  const conv = loadFixture('conversation-with-pasted.json');
  const { dir, cleanup } = makeTempDir();
  try {
    const api = fakeApi({});
    const manifest = await processAttachments({ conversation: conv, api, orgUuid: 'ORG', cacheDir: dir });
    const att = manifest.get('msg-1').attachments[0];
    assert.equal(att.kind, 'pasted');
    assert.equal(att.localPath, 'files/pasted-1.txt');
    const content = readFileSync(join(dir, 'files/pasted-1.txt'), 'utf8');
    assert.equal(content, 'ERROR line 1\nERROR line 2\nERROR line 3');
  } finally { cleanup(); }
});

test('processAttachments dedupes pasted-N across multiple messages', async () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    projects_v2_uuid: null,
    chat_messages: [
      {
        uuid: 'm1', sender: 'human',
        content: [{ type: 'text', text: 'first paste' }],
        attachments: [{ file_name: 'a.txt', extracted_content: 'first message paste' }],
        files_v2: [],
      },
      {
        uuid: 'm2', sender: 'human',
        content: [{ type: 'text', text: 'second paste' }],
        attachments: [{ file_name: 'b.txt', extracted_content: 'second message paste' }],
        files_v2: [],
      },
    ],
  };
  const { dir, cleanup } = makeTempDir();
  try {
    const api = fakeApi({});
    const manifest = await processAttachments({ conversation: conv, api, orgUuid: 'ORG', cacheDir: dir });
    const m1Path = manifest.get('m1').attachments[0].localPath;
    const m2Path = manifest.get('m2').attachments[0].localPath;
    assert.notEqual(m1Path, m2Path);
    assert.equal(readFileSync(join(dir, m1Path), 'utf8'), 'first message paste');
    assert.equal(readFileSync(join(dir, m2Path), 'utf8'), 'second message paste');
  } finally { cleanup(); }
});

test('processAttachments increments pasted-N counter per message', async () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    projects_v2_uuid: null,
    chat_messages: [{
      uuid: 'm1', sender: 'human',
      content: [{ type: 'text', text: 'two pastes' }],
      attachments: [
        { file_name: 'paste1.txt', extracted_content: 'first' },
        { file_name: 'paste2.txt', extracted_content: 'second' },
      ],
      files_v2: [],
    }],
  };
  const { dir, cleanup } = makeTempDir();
  try {
    const api = fakeApi({});
    const manifest = await processAttachments({ conversation: conv, api, orgUuid: 'ORG', cacheDir: dir });
    const paths = manifest.get('m1').attachments.map(a => a.localPath);
    assert.deepEqual(paths, ['files/pasted-1.txt', 'files/pasted-2.txt']);
  } finally { cleanup(); }
});

test('processAttachments fetches project docs when projects_v2_uuid is set', async () => {
  const conv = {
    uuid: 'p', name: 'p', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    projects_v2_uuid: 'proj-123',
    chat_messages: [{ uuid: 'm1', sender: 'human',
      content: [{ type: 'text', text: 'hi' }], attachments: [], files_v2: [] }],
  };
  const { dir, cleanup } = makeTempDir();
  try {
    const api = {
      async getJson(url) {
        if (url.endsWith('/projects/proj-123/docs')) {
          return [{ uuid: 'd1', file_name: 'overview.md', content: '# Overview\nhello' }];
        }
        throw new Error('unexpected url');
      },
      async getBinary() { throw new Error('not used'); },
    };
    const manifest = await processAttachments({ conversation: conv, api, orgUuid: 'ORG', cacheDir: dir });
    assert.ok(existsSync(join(dir, 'files/project-overview.md')));
    assert.equal(manifest.get('__project__').projectDocs[0].localPath, 'files/project-overview.md');
  } finally { cleanup(); }
});

test('processAttachments extracts create_file tool_use into files/', async () => {
  const conv = loadFixture('conversation-with-created-files.json');
  const { dir, cleanup } = makeTempDir();
  try {
    const api = fakeApi({});
    const manifest = await processAttachments({ conversation: conv, api, orgUuid: 'ORG', cacheDir: dir });

    assert.equal(readFileSync(join(dir, 'files/deploy.sh'), 'utf8'), '#!/bin/bash\necho hello\n');
    assert.equal(readFileSync(join(dir, 'files/notes.md'), 'utf8'), '# Notes\nhello\n');

    const m2 = manifest.get('m2');
    assert.equal(m2.created[0].localPath, 'files/deploy.sh');
    assert.equal(m2.created[0].name, 'deploy.sh');

    const m3 = manifest.get('m3');
    assert.equal(m3.created[0].localPath, 'files/notes.md');
  } finally { cleanup(); }
});

test('processAttachments dedupes created files with same basename across messages', async () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    projects_v2_uuid: null,
    chat_messages: [
      { uuid: 'a', sender: 'assistant',
        content: [{ type: 'tool_use', name: 'create_file',
          input: { path: '/home/claude/x.txt', file_text: 'first' } }],
        attachments: [], files_v2: [] },
      { uuid: 'b', sender: 'assistant',
        content: [{ type: 'tool_use', name: 'create_file',
          input: { path: '/home/claude/x.txt', file_text: 'second' } }],
        attachments: [], files_v2: [] },
    ],
  };
  const { dir, cleanup } = makeTempDir();
  try {
    const api = fakeApi({});
    const manifest = await processAttachments({ conversation: conv, api, orgUuid: 'ORG', cacheDir: dir });
    const aPath = manifest.get('a').created[0].localPath;
    const bPath = manifest.get('b').created[0].localPath;
    assert.notEqual(aPath, bPath);
    assert.equal(readFileSync(join(dir, aPath), 'utf8'), 'first');
    assert.equal(readFileSync(join(dir, bPath), 'utf8'), 'second');
  } finally { cleanup(); }
});

test('processAttachments skips create_file with missing file_text', async () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    projects_v2_uuid: null,
    chat_messages: [
      { uuid: 'a', sender: 'assistant',
        content: [{ type: 'tool_use', name: 'create_file',
          input: { path: '/home/claude/empty.txt' } }],
        attachments: [], files_v2: [] },
    ],
  };
  const { dir, cleanup } = makeTempDir();
  try {
    const api = fakeApi({});
    const manifest = await processAttachments({ conversation: conv, api, orgUuid: 'ORG', cacheDir: dir });
    assert.equal(manifest.get('a'), undefined);
  } finally { cleanup(); }
});

test('processAttachments tolerates project docs fetch failure', async () => {
  const conv = {
    uuid: 'p', name: 'p', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    projects_v2_uuid: 'proj-123',
    chat_messages: [{ uuid: 'm1', sender: 'human',
      content: [{ type: 'text', text: 'hi' }], attachments: [], files_v2: [] }],
  };
  const { dir, cleanup } = makeTempDir();
  try {
    const api = {
      async getJson() { throw Object.assign(new Error('boom'), { exitCode: 6 }); },
      async getBinary() { throw new Error('unused'); },
    };
    const manifest = await processAttachments({ conversation: conv, api, orgUuid: 'ORG', cacheDir: dir });
    assert.equal(manifest.get('__project__'), undefined);
  } finally { cleanup(); }
});
