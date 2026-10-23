#!/usr/bin/env node
// redis-exec.js — the connection and decoding layer behind redis-query.sh, which owns argument parsing, the
// read-command allowlist, masking and the audit line. This script runs one request that was already checked,
// and checks the command again.
//
//   DBTOOLS_REDIS_URI=redis[s]://... node redis-exec.js '<spec>'
//
// The URI comes from the environment, never from argv, so ps never shows it. The spec carries no secret:
//   { op: "inspect" | "cmd" | "scan" | "decode-file", key, cmd, args, decode,
//     scan: { pattern, count, maxKeys, maxIterations, timeoutMs }, file, connectTimeout }
//
// Values are decoded from MessagePack when they parse as MessagePack, and printed as UTF-8 strings otherwise.
'use strict';

const fs = require('fs');
const Redis = require('ioredis');
const { decode } = require('@msgpack/msgpack');

// Mirrors REDIS_READ_COMMANDS in lib/safety.sh; tests/test_redis_query.bats keeps the two equal.
const READ_COMMANDS = new Set([
  'GET', 'MGET', 'TTL', 'PTTL', 'EXISTS', 'TYPE', 'STRLEN', 'GETRANGE',
  'HGET', 'HGETALL', 'HKEYS', 'HVALS', 'HLEN', 'HMGET',
  'SMEMBERS', 'SCARD', 'SISMEMBER',
  'LRANGE', 'LLEN', 'LINDEX',
  'ZRANGE', 'ZCARD', 'ZSCORE',
  'MEMORY', 'DBSIZE',
]);
// Commands with write or administration subcommands, pinned to their read one. Their key follows the
// subcommand (MEMORY USAGE <key>), unlike GET <key>.
const SUBCOMMANDS = { MEMORY: new Set(['USAGE']) };

const jsonReplacer = (_key, value) => {
  if (typeof value === 'bigint') return value.toString();
  if (value instanceof Map) return Object.fromEntries(value);
  if (value instanceof Uint8Array) return Buffer.from(value).toString('utf8');
  return value;
};
const out = (value) => process.stdout.write(`${JSON.stringify(value, jsonReplacer, 2)}\n`);

const decodeValue = (buffer) => {
  if (buffer == null) return { present: false, value: null };
  try {
    return { present: true, encoding: 'msgpack', value: decode(buffer) };
  } catch {
    return { present: true, encoding: 'string', value: buffer.toString('utf8') };
  }
};

const checkedCommand = (cmd, args) => {
  const name = String(cmd || '').toUpperCase();
  if (!READ_COMMANDS.has(name)) throw new Error(`command '${name}' is not a read command`);
  if (SUBCOMMANDS[name] && !SUBCOMMANDS[name].has(String(args[0] || '').toUpperCase())) {
    throw new Error(`${name} only allows ${[...SUBCOMMANDS[name]].join(', ')}`);
  }
  return name;
};

async function scan(client, { pattern, count = 1000, maxKeys = 1000, maxIterations = 1000 }) {
  // maxIterations bounds the round trips separately from maxKeys: a sparse MATCH can walk a large keyspace
  // for a long time while finding nothing.
  const keys = [];
  let cursor = '0';
  let iterations = 0;
  do {
    const [next, batch] = await client.scan(cursor, 'MATCH', pattern, 'COUNT', count);
    keys.push(...batch.slice(0, maxKeys - keys.length));
    cursor = next;
    iterations += 1;
  } while (cursor !== '0' && keys.length < maxKeys && iterations < maxIterations);
  const complete = cursor === '0';
  return {
    op: 'scan', pattern, count: keys.length, iterations, complete, hit_max_keys: keys.length >= maxKeys,
    ...(complete ? {} : { note: 'the scan stopped before the end of the keyspace, so this is a partial sample' }),
    keys,
  };
}

async function inspect(client, key, wantDecode) {
  if (!(await client.exists(key))) return { op: 'inspect', key, exists: 0 };
  const [ttl, type] = await Promise.all([client.ttl(key), client.type(key)]);
  const result = {
    op: 'inspect', key, exists: 1, ttl_seconds: ttl,
    ttl_human: ttl >= 0 ? `${(ttl / 86400).toFixed(2)}d` : ttl === -1 ? 'no-expiry' : 'n/a',
    type,
  };
  if (type !== 'string') return { ...result, note: `a ${type}: read it with the matching --cmd` };
  result.strlen = await client.strlen(key);
  if (wantDecode) {
    const { encoding, value } = decodeValue(await client.getBuffer(key));
    Object.assign(result, { encoding, value });
  }
  return result;
}

async function command(client, { cmd, args = [], key, decode: wantDecode }) {
  const name = checkedCommand(cmd, args);
  if (name === 'GET' && wantDecode !== false) {
    return { op: 'cmd', cmd: name, key, ...decodeValue(await client.getBuffer(key)) };
  }
  const keyFirst = !SUBCOMMANDS[name];
  const callArgs = key == null ? args : keyFirst ? [key, ...args] : [...args, key];
  return { op: 'cmd', cmd: name, key: key ?? null, value: await client.call(name, ...callArgs) };
}

async function main() {
  const spec = JSON.parse(process.argv[2] || '{}');

  // Offline: decode a local file, for the tests.
  if (spec.op === 'decode-file') {
    out({ op: 'decode-file', ...decodeValue(fs.readFileSync(spec.file)) });
    return;
  }

  const uri = process.env.DBTOOLS_REDIS_URI;
  if (!uri) throw new Error('DBTOOLS_REDIS_URI is not set');
  delete process.env.DBTOOLS_REDIS_URI;

  const connectTimeout = spec.connectTimeout || 8000;
  const client = new Redis(uri, {
    connectTimeout,
    maxRetriesPerRequest: 1,
    retryStrategy: () => null, // a one-shot CLI fails fast instead of reconnecting
  });
  let connectionError = null;
  client.on('error', (error) => {
    connectionError = connectionError || error;
  });

  // A hung TLS handshake or a runaway scan must not wedge the CLI.
  const budgetMs = spec.op === 'scan' ? spec.scan.timeoutMs || 60000 : connectTimeout + 4000;
  const watchdog = setTimeout(() => {
    client.disconnect();
    process.stderr.write(`timed out after ${budgetMs} ms\n`);
    process.exit(1);
  }, budgetMs);

  try {
    if (spec.op === 'scan') out(await scan(client, spec.scan));
    else if (spec.op === 'inspect') out(await inspect(client, spec.key, spec.decode !== false));
    else if (spec.op === 'cmd') out(await command(client, spec));
    else throw new Error(`unknown op '${spec.op}'`);
  } finally {
    clearTimeout(watchdog);
    await client.quit().catch(() => client.disconnect());
  }
  if (connectionError) throw connectionError;
}

main().then(
  () => process.exit(0),
  (error) => {
    process.stderr.write(`${error && error.message ? error.message : String(error)}\n`);
    process.exit(1);
  },
);
