import { readdirSync, statSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { ChatReaderError } from './errors.mjs';

// Chat folders are named by conversation UUID. Anything else under the cache root is not ours to
// list or delete, which matters when CLAUDE_CHAT_FETCH_CACHE points at a shared directory.
const CHAT_DIR_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function folderSizeBytes(path) {
  let total = 0;
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const sub = join(path, entry.name);
    if (entry.isDirectory()) total += folderSizeBytes(sub);
    else total += statSync(sub).size;
  }
  return total;
}

function describe(cacheDir, uuid) {
  const dir = join(cacheDir, uuid);
  let name = '(no meta)';
  try {
    const meta = JSON.parse(readFileSync(join(dir, 'meta.json'), 'utf8'));
    if (meta.name) name = meta.name;
  } catch { /* meta missing or unreadable — keep default */ }
  let size = 0;
  let ageMs = 0;
  try {
    size = folderSizeBytes(dir);
    ageMs = Date.now() - statSync(dir).mtimeMs;
  } catch { /* dir vanished mid-scan — treat as empty */ }
  return { uuid, name, size, ageMs };
}

export function listCached(cacheDir) {
  if (!existsSync(cacheDir)) return [];
  return readdirSync(cacheDir, { withFileTypes: true })
    .filter(e => e.isDirectory() && CHAT_DIR_RE.test(e.name))
    .map(e => describe(cacheDir, e.name));
}

export function cleanCache(cacheDir, options = {}) {
  if (!existsSync(cacheDir)) return [];
  const all = listCached(cacheDir);

  let targets;
  if (options.all) {
    targets = all;
  } else if (options.uuid) {
    const found = all.find(e => e.uuid === options.uuid);
    if (!found) throw new ChatReaderError(`chat not found: ${options.uuid}`, 6);
    targets = [found];
  } else if (typeof options.olderThanMs === 'number') {
    targets = all.filter(e => e.ageMs >= options.olderThanMs);
  } else {
    return [];
  }

  if (!options.dryRun) {
    for (const t of targets) {
      rmSync(join(cacheDir, t.uuid), { recursive: true, force: true });
    }
  }
  return targets;
}
