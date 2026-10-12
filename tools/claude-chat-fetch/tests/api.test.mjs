import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createClient } from '../lib/api.mjs';

function fakeFetch(handler) {
  return async (url, opts) => handler(url, opts);
}

test('createClient sends sessionKey cookie on getJson', async () => {
  let captured;
  const client = createClient({
    sessionKey: 'sk-ant-sid01-test',
    fetch: fakeFetch(async (url, opts) => {
      captured = { url, opts };
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    }),
  });
  await client.getJson('https://claude.ai/api/foo');
  assert.match(captured.opts.headers.Cookie, /sessionKey=sk-ant-sid01-test/);
  assert.equal(captured.opts.headers.Accept, 'application/json');
});

test('getJson throws exit-5 error on HTTP 401', async () => {
  const client = createClient({
    sessionKey: 'sk-ant-sid01-test',
    fetch: fakeFetch(async () => new Response('unauthorized', { status: 401 })),
  });
  await assert.rejects(
    () => client.getJson('https://claude.ai/api/foo'),
    err => err.exitCode === 5,
  );
});

test('getJson throws exit-6 on HTTP 404', async () => {
  const client = createClient({
    sessionKey: 'sk-ant-sid01-test',
    fetch: fakeFetch(async () => new Response('not found', { status: 404 })),
  });
  await assert.rejects(
    () => client.getJson('https://claude.ai/api/foo'),
    err => err.exitCode === 6,
  );
});

test('getJson throws exit-8 on HTTP 500', async () => {
  const client = createClient({
    sessionKey: 'sk-ant-sid01-test',
    fetch: fakeFetch(async () => new Response('boom', { status: 500 })),
  });
  await assert.rejects(
    () => client.getJson('https://claude.ai/api/foo'),
    err => err.exitCode === 8,
  );
});

test('getJson throws exit-7 on network failure', async () => {
  const client = createClient({
    sessionKey: 'sk-ant-sid01-test',
    fetch: fakeFetch(async () => { throw new Error('ENETUNREACH'); }),
  });
  await assert.rejects(
    () => client.getJson('https://claude.ai/api/foo'),
    err => err.exitCode === 7,
  );
});

test('getBinary returns ArrayBuffer on success', async () => {
  const bytes = new Uint8Array([1, 2, 3, 4]);
  const client = createClient({
    sessionKey: 'sk-ant-sid01-test',
    fetch: fakeFetch(async () => new Response(bytes, { status: 200 })),
  });
  const buf = await client.getBinary('https://claude.ai/api/files/x/contents');
  assert.deepEqual(new Uint8Array(buf), bytes);
});

test('error messages never include sessionKey value', async () => {
  const client = createClient({
    sessionKey: 'sk-ant-sid01-SECRET-VALUE',
    fetch: fakeFetch(async () => new Response('unauthorized', { status: 401 })),
  });
  try {
    await client.getJson('https://claude.ai/api/foo');
    assert.fail('should have thrown');
  } catch (err) {
    assert.ok(!err.message.includes('SECRET-VALUE'), 'secret leaked into error');
  }
});

import { readFileSync } from 'node:fs';
import { resolveOrgUuid } from '../lib/api.mjs';

function loadFixture(name) {
  return JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8'));
}

test('resolveOrgUuid returns sole org uuid', async () => {
  const orgs = loadFixture('organizations.json');
  const client = createClient({
    sessionKey: 'sk-ant-sid01-test',
    fetch: fakeFetch(async () => new Response(JSON.stringify(orgs), { status: 200 })),
  });
  const result = await resolveOrgUuid(client);
  assert.equal(result.uuid, '11111111-2222-3333-4444-555555555555');
  assert.equal(result.warnings.length, 0);
});

test('resolveOrgUuid picks first when multiple orgs and emits warning', async () => {
  const orgs = [
    { uuid: 'aaaa1111-2222-3333-4444-555555555555', name: 'Personal' },
    { uuid: 'bbbb1111-2222-3333-4444-555555555555', name: 'Acme Inc' },
  ];
  const client = createClient({
    sessionKey: 'sk-ant-sid01-test',
    fetch: fakeFetch(async () => new Response(JSON.stringify(orgs), { status: 200 })),
  });
  const result = await resolveOrgUuid(client);
  assert.equal(result.uuid, 'aaaa1111-2222-3333-4444-555555555555');
  assert.equal(result.warnings.length, 1);
  assert.match(result.warnings[0], /multiple organizations/);
  assert.match(result.warnings[0], /Personal/);
  assert.match(result.warnings[0], /Acme Inc/);
});

test('resolveOrgUuid throws when no orgs returned', async () => {
  const client = createClient({
    sessionKey: 'sk-ant-sid01-test',
    fetch: fakeFetch(async () => new Response('[]', { status: 200 })),
  });
  await assert.rejects(() => resolveOrgUuid(client), err => err.exitCode === 8);
});
