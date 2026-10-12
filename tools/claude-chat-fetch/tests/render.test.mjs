import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { renderConversation } from '../lib/render.mjs';

function loadFixture(name) {
  return JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8'));
}

test('renderConversation produces header with name, dates, message count', () => {
  const conv = loadFixture('conversation-minimal.json');
  const md = renderConversation(conv, { attachmentManifest: new Map() });
  assert.match(md, /^# Hello chat$/m);
  assert.match(md, /Created: 2026-04-12/);
  assert.match(md, /Updated: 2026-04-12/);
  assert.match(md, /2 messages/);
});

test('renderConversation renders human and assistant turns', () => {
  const conv = loadFixture('conversation-minimal.json');
  const md = renderConversation(conv, { attachmentManifest: new Map() });
  assert.match(md, /## 👤 Human\n\nHi Claude/);
  assert.match(md, /## 🤖 Assistant\n\nHello!/);
});

test('renderConversation preserves message order', () => {
  const conv = loadFixture('conversation-minimal.json');
  const md = renderConversation(conv, { attachmentManifest: new Map() });
  const humanIdx = md.indexOf('Hi Claude');
  const assistantIdx = md.indexOf('Hello!');
  assert.ok(humanIdx > 0 && humanIdx < assistantIdx);
});

test('renderConversation handles empty text blocks gracefully', () => {
  const conv = {
    ...loadFixture('conversation-minimal.json'),
    chat_messages: [{
      uuid: 'm', sender: 'human',
      content: [{ type: 'text', text: '' }],
      attachments: [], files_v2: [],
    }],
  };
  const md = renderConversation(conv, { attachmentManifest: new Map() });
  assert.match(md, /## 👤 Human/);
});

test('renderConversation renders thinking blocks as blockquote', () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    chat_messages: [{
      uuid: 'm', sender: 'assistant',
      content: [
        { type: 'thinking', thinking: 'reasoning step one\nreasoning step two' },
        { type: 'text', text: 'Final answer' },
      ],
      attachments: [], files_v2: [],
    }],
  };
  const md = renderConversation(conv, { attachmentManifest: new Map() });
  assert.match(md, /> 💭 _thinking_/);
  assert.match(md, /> reasoning step one/);
  assert.match(md, /> reasoning step two/);
  assert.match(md, /Final answer/);
});

test('renderConversation renders tool_use as fenced block with infostring', () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    chat_messages: [{
      uuid: 'm', sender: 'assistant',
      content: [{
        type: 'tool_use', name: 'bash',
        input: { command: 'ls -la' },
      }],
      attachments: [], files_v2: [],
    }],
  };
  const md = renderConversation(conv, { attachmentManifest: new Map() });
  assert.match(md, /```tool:bash/);
  assert.match(md, /"command": "ls -la"/);
});

test('renderConversation renders tool_result as fenced block', () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    chat_messages: [{
      uuid: 'm', sender: 'human',
      content: [{
        type: 'tool_result',
        content: [{ type: 'text', text: 'total 24\ndrwxr-xr-x' }],
      }],
      attachments: [], files_v2: [],
    }],
  };
  const md = renderConversation(conv, { attachmentManifest: new Map() });
  assert.match(md, /```tool_result/);
  assert.match(md, /total 24/);
});

test('renderConversation includes attachment links from manifest', () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    chat_messages: [{
      uuid: 'm1', sender: 'human',
      content: [{ type: 'text', text: 'Look at this' }],
      attachments: [], files_v2: [],
    }],
  };
  const manifest = new Map([['m1', {
    attachments: [{ name: 'screenshot.png', localPath: 'files/screenshot.png', kind: 'image', size: 234000 }],
  }]]);
  const md = renderConversation(conv, { attachmentManifest: manifest });
  assert.match(md, /📎 \*\*Attachments:\*\*/);
  assert.match(md, /\[screenshot\.png\]\(files\/screenshot\.png\)/);
});

test('renderConversation includes created files section', () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    chat_messages: [{ uuid: 'm1', sender: 'assistant', content: [{ type: 'text', text: 'made it' }], attachments: [], files_v2: [] }],
  };
  const manifest = new Map([['m1', {
    attachments: [],
    created: [{ name: 'deploy.sh', localPath: 'files/deploy.sh', size: 1024 }],
  }]]);
  const md = renderConversation(conv, { attachmentManifest: manifest });
  assert.match(md, /📄 \*\*Created by Claude:\*\*/);
  assert.match(md, /\[deploy\.sh\]\(files\/deploy\.sh\)/);
});

test('renderConversation renders artifact with versions in manifest', () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    chat_messages: [{ uuid: 'm5', sender: 'assistant', content: [{ type: 'text', text: 'Done' }], attachments: [], files_v2: [] }],
  };
  const manifest = new Map([['m5', {
    attachments: [],
    artifacts: [{
      title: 'Payment Validator',
      localPath: 'files/artifact-payment-validator.ts',
      versions: ['files/artifact-payment-validator.v1.ts', 'files/artifact-payment-validator.v2.ts'],
    }],
  }]]);
  const md = renderConversation(conv, { attachmentManifest: manifest });
  assert.match(md, /🎨 \*\*Artifact\*\*: \[Payment Validator\]/);
  assert.match(md, /versions: \[v1\]/);
});

test('renderToolUse elides string fields longer than 2000 chars', () => {
  const longText = 'x'.repeat(5000);
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    chat_messages: [{
      uuid: 'm', sender: 'assistant',
      content: [{
        type: 'tool_use', name: 'create_file',
        input: { description: 'short', path: '/x', file_text: longText },
      }],
      attachments: [], files_v2: [],
    }],
  };
  const md = renderConversation(conv, { attachmentManifest: new Map() });
  assert.ok(!md.includes(longText), 'long string should be elided');
  assert.match(md, /<elided: 5000 chars>/);
  assert.match(md, /"description": "short"/);
  assert.match(md, /"path": "\/x"/);
});

test('renderToolUse leaves short strings untouched', () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    chat_messages: [{
      uuid: 'm', sender: 'assistant',
      content: [{
        type: 'tool_use', name: 'bash',
        input: { command: 'ls -la /etc' },
      }],
      attachments: [], files_v2: [],
    }],
  };
  const md = renderConversation(conv, { attachmentManifest: new Map() });
  assert.match(md, /"command": "ls -la \/etc"/);
  assert.ok(!md.includes('<elided'));
});

test('renderToolUse elides nested string values inside arrays and objects', () => {
  const longText = 'y'.repeat(3000);
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    chat_messages: [{
      uuid: 'm', sender: 'assistant',
      content: [{
        type: 'tool_use', name: 'some_tool',
        input: { items: [{ nested: { deeplyNestedField: longText } }] },
      }],
      attachments: [], files_v2: [],
    }],
  };
  const md = renderConversation(conv, { attachmentManifest: new Map() });
  assert.ok(!md.includes(longText));
  assert.match(md, /<elided: 3000 chars>/);
});

test('renderToolResult truncates results longer than 30 lines', () => {
  const lines = Array.from({ length: 100 }, (_, i) => `line ${i + 1}`);
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    chat_messages: [{
      uuid: 'm', sender: 'human',
      content: [{
        type: 'tool_result',
        content: [{ type: 'text', text: lines.join('\n') }],
      }],
      attachments: [], files_v2: [],
    }],
  };
  const md = renderConversation(conv, { attachmentManifest: new Map() });
  assert.match(md, /line 1/);
  assert.match(md, /line 22/);
  assert.ok(!md.includes('line 50'), 'middle should be elided');
  assert.match(md, /line 93/);
  assert.match(md, /line 100/);
  assert.match(md, /<70 lines elided>/);
});

test('renderToolResult leaves short results untouched', () => {
  const conv = {
    uuid: 'x', name: 't', created_at: '2026-04-12T00:00:00Z', updated_at: '2026-04-12T00:00:00Z',
    chat_messages: [{
      uuid: 'm', sender: 'human',
      content: [{
        type: 'tool_result',
        content: [{ type: 'text', text: 'short\nresult\nhere' }],
      }],
      attachments: [], files_v2: [],
    }],
  };
  const md = renderConversation(conv, { attachmentManifest: new Map() });
  assert.match(md, /short\nresult\nhere/);
  assert.ok(!md.includes('lines elided'));
});
