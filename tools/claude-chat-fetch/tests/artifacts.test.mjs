import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { reconstructArtifacts, slugify, extensionForArtifact } from '../lib/artifacts.mjs';

function loadFixture(name) {
  return JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8'));
}

test('slugify lowercases and replaces non-alnum with dashes', () => {
  assert.equal(slugify('Payment Validator!'), 'payment-validator');
  assert.equal(slugify('Foo / Bar (v2)'), 'foo-bar-v2');
  assert.equal(slugify('   '), '');
});

test('extensionForArtifact maps known artifact types', () => {
  assert.equal(extensionForArtifact({ type: 'text/markdown' }), 'md');
  assert.equal(extensionForArtifact({ type: 'application/vnd.ant.code', language: 'typescript' }), 'ts');
  assert.equal(extensionForArtifact({ type: 'application/vnd.ant.code', language: 'python' }), 'py');
  assert.equal(extensionForArtifact({ type: 'image/svg+xml' }), 'svg');
  assert.equal(extensionForArtifact({ type: 'text/html' }), 'html');
  assert.equal(extensionForArtifact({ type: 'unknown' }), 'txt');
});

test('reconstructArtifacts produces v1, v2, v3 for 3-version chain', () => {
  const conv = loadFixture('conversation-with-artifacts.json');
  const map = reconstructArtifacts(conv);
  const versions = map.get('art-1');
  assert.equal(versions.length, 3);
  assert.equal(versions[0].content, "console.log('v1');");
  assert.equal(versions[1].content, "console.log('v2 better');");
  assert.equal(versions[2].content, "console.log('v3 final');");
  assert.equal(versions[0].messageUuid, 'm2');
  assert.equal(versions[2].messageUuid, 'm5');
});

test('reconstructArtifacts applies update string replacement correctly', () => {
  const conv = {
    chat_messages: [
      { uuid: 'a', sender: 'assistant', content: [{
        type: 'tool_use', name: 'artifacts',
        input: { command: 'create', id: 'x', title: 'T', type: 'text/plain', content: 'foo bar baz' },
      }]},
      { uuid: 'b', sender: 'assistant', content: [{
        type: 'tool_use', name: 'artifacts',
        input: { command: 'update', id: 'x', old_str: 'bar', new_str: 'BAR' },
      }]},
    ],
  };
  const map = reconstructArtifacts(conv);
  assert.equal(map.get('x')[1].content, 'foo BAR baz');
});

test('reconstructArtifacts tolerates malformed tool_use (no content)', () => {
  const conv = {
    chat_messages: [{ uuid: 'a', sender: 'assistant', content: [{
      type: 'tool_use', name: 'artifacts',
      input: { command: 'create', id: 'y', title: 'T', type: 'text/plain' },
    }]}],
  };
  const map = reconstructArtifacts(conv);
  assert.equal(map.get('y')[0].content, '');
  assert.equal(map.get('y')[0].malformed, true);
});
