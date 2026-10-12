import { ChatReaderError } from './errors.mjs';

const STATUS_TO_EXIT = { 401: 5, 404: 6 };

export function createClient({ sessionKey, fetch: fetchImpl = globalThis.fetch }) {
  const baseHeaders = {
    Cookie: `sessionKey=${sessionKey}`,
    Accept: 'application/json',
    'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0',
    'Accept-Language': 'en-US,en;q=0.5',
    Origin: 'https://claude.ai',
    Referer: 'https://claude.ai/',
  };

  async function request(url, accept) {
    let response;
    try {
      response = await fetchImpl(url, { headers: { ...baseHeaders, Accept: accept } });
    } catch (err) {
      throw new ChatReaderError(`network error: ${err.message}`, 7);
    }
    if (!response.ok) {
      const exitCode = STATUS_TO_EXIT[response.status] ?? 8;
      const reason = exitCode === 5
        ? 'sessionKey likely expired; refresh it (see README)'
        : exitCode === 6
        ? `not found: ${url}`
        : `unexpected HTTP ${response.status}`;
      throw new ChatReaderError(reason, exitCode);
    }
    return response;
  }

  return {
    async getJson(url) {
      const r = await request(url, 'application/json');
      return r.json();
    },
    async getBinary(url) {
      const r = await request(url, '*/*');
      return r.arrayBuffer();
    },
  };
}

export async function resolveOrgUuid(client) {
  const orgs = await client.getJson('https://claude.ai/api/organizations');
  if (!Array.isArray(orgs) || orgs.length === 0) {
    throw new ChatReaderError('no organizations returned by claude.ai', 8);
  }
  const warnings = [];
  if (orgs.length > 1) {
    const list = orgs.map(o => `  ${o.name} = ${o.uuid}`).join('\n');
    warnings.push(`multiple organizations found, using first; set org_uuid manually in .session if wrong:\n${list}`);
  }
  return { uuid: orgs[0].uuid, warnings };
}
