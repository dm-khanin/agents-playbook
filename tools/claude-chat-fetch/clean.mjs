#!/usr/bin/env node
import { cacheDir } from './lib/paths.mjs';
import { listCached, cleanCache } from './lib/cleanup.mjs';
import { ChatReaderError } from './lib/errors.mjs';

const CACHE_DIR = cacheDir();

const USAGE = `usage:
  clean.mjs                          list cached chats (uuid, name, age, size)
  clean.mjs --all                    delete entire cache
  clean.mjs --uuid <id>              delete one chat folder
  clean.mjs --older-than <N>d        delete chats older than N days
  clean.mjs --dry-run [...]          show what would be deleted, do nothing

  use exactly one selector with --dry-run if combined.`;

function parseDays(spec) {
  const m = /^(\d+)d$/.exec(spec);
  if (!m) throw new ChatReaderError(`bad --older-than value: ${spec} (expected e.g. 30d)`, 2);
  return parseInt(m[1], 10) * 24 * 60 * 60 * 1000;
}

function fmtBytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

function fmtAge(ms) {
  const sec = Math.floor(ms / 1000);
  if (sec < 60) return `${sec}s`;
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h`;
  const days = Math.floor(hr / 24);
  return `${days}d`;
}

function printTable(entries, header = 'cached chats:') {
  if (entries.length === 0) {
    console.log('cache is empty');
    return;
  }
  console.log(header);
  for (const e of entries) {
    console.log(`  ${e.uuid}  ${fmtAge(e.ageMs).padStart(6)}  ${fmtBytes(e.size).padStart(8)}  ${e.name}`);
  }
  const totalSize = entries.reduce((s, e) => s + e.size, 0);
  console.log(`  total: ${entries.length} chats, ${fmtBytes(totalSize)}`);
}

function main() {
  const args = process.argv.slice(2);
  const options = {};
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--all') options.all = true;
    else if (a === '--uuid') options.uuid = args[++i];
    else if (a === '--older-than') options.olderThanMs = parseDays(args[++i]);
    else if (a === '--dry-run') options.dryRun = true;
    else if (a === '--help' || a === '-h') { console.log(USAGE); process.exit(0); }
    else { console.error(`unknown arg: ${a}\n\n${USAGE}`); process.exit(2); }
  }

  const hasSelector = options.all || options.uuid || typeof options.olderThanMs === 'number';
  if (!hasSelector) {
    printTable(listCached(CACHE_DIR));
    return;
  }

  const result = cleanCache(CACHE_DIR, options);
  const verb = options.dryRun ? 'would delete' : 'deleted';
  printTable(result, `${verb} ${result.length} chats:`);
}

try {
  main();
} catch (err) {
  if (err instanceof ChatReaderError) {
    console.error(err.message);
    process.exit(err.exitCode);
  }
  console.error(`internal error: ${err.stack ?? err.message}`);
  process.exit(1);
}
