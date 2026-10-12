import { readFileSync, statSync, writeFileSync, chmodSync } from 'node:fs';
import { ChatReaderError } from './errors.mjs';

function setupHint(path) {
  return `
sessionKey is not configured. To get it:
  1. Open https://claude.ai in a browser where you are logged in
  2. DevTools (F12) → Application → Cookies → https://claude.ai
  3. Find the cookie named "sessionKey" (starts with sk-ant-sid01-)
  4. Copy the value and run:
       umask 077
       mkdir -p "$(dirname '${path}')"
       echo "sessionKey=<paste>" > '${path}'
  Set CLAUDE_CHAT_FETCH_SESSION to keep the file somewhere else.
`.trim();
}

export function loadSession(path) {
  let stats;
  try {
    stats = statSync(path);
  } catch {
    throw new ChatReaderError(`session file missing: ${path}\n\n${setupHint(path)}`, 3);
  }

  const mode = stats.mode & 0o777;
  if (mode & 0o077) {
    throw new ChatReaderError(
      `session file has insecure permissions (${mode.toString(8)}); run: chmod 600 ${path}`,
      4,
    );
  }

  const raw = readFileSync(path, 'utf8');
  const session = {};
  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq < 0) continue;
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim();
    if (key === 'sessionKey') session.sessionKey = value;
    else if (key === 'org_uuid') session.orgUuid = value;
  }

  if (!session.sessionKey) {
    throw new ChatReaderError(`sessionKey missing from ${path}\n\n${setupHint(path)}`, 3);
  }

  return session;
}

export function saveOrgUuid(path, orgUuid) {
  const raw = readFileSync(path, 'utf8');
  const lines = raw.split('\n').filter(l => !l.startsWith('org_uuid='));
  const stripped = lines.join('\n').replace(/\n+$/, '');
  const next = `${stripped}\norg_uuid=${orgUuid}\n`;
  writeFileSync(path, next);
  chmodSync(path, 0o600);
}
