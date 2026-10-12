#!/usr/bin/env node
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { sessionPath, cacheDir } from './lib/paths.mjs';
import { parseChatUrl } from './lib/url.mjs';
import { loadSession, saveOrgUuid } from './lib/session.mjs';
import { createClient, resolveOrgUuid } from './lib/api.mjs';
import { processAttachments } from './lib/attachments.mjs';
import { renderConversation } from './lib/render.mjs';
import { ChatReaderError } from './lib/errors.mjs';

const SESSION_PATH = sessionPath();
const CACHE_DIR = cacheDir();

async function main() {
  const url = process.argv[2];
  if (!url) {
    console.error('usage: fetch-chat.mjs <claude.ai/chat/<uuid> URL>');
    process.exit(2);
  }

  const chatUuid = parseChatUrl(url);
  const session = loadSession(SESSION_PATH);
  const client = createClient({ sessionKey: session.sessionKey });

  let orgUuid = session.orgUuid;
  if (!orgUuid) {
    const result = await resolveOrgUuid(client);
    orgUuid = result.uuid;
    for (const w of result.warnings) console.error(`[warn] ${w}`);
    saveOrgUuid(SESSION_PATH, orgUuid);
  }

  const apiUrl =
    `https://claude.ai/api/organizations/${orgUuid}/chat_conversations/${chatUuid}` +
    `?tree=True&rendering_mode=messages&render_all_tools=true`;
  const conversation = await client.getJson(apiUrl);

  const chatDir = join(CACHE_DIR, chatUuid);
  mkdirSync(chatDir, { recursive: true });

  writeFileSync(join(chatDir, 'raw.json'), JSON.stringify(conversation, null, 2));

  const manifest = await processAttachments({
    conversation, api: client, orgUuid, cacheDir: chatDir,
  });

  const markdown = renderConversation(conversation, { attachmentManifest: manifest });
  const chatMdPath = join(chatDir, 'chat.md');
  writeFileSync(chatMdPath, markdown);

  const meta = {
    uuid: conversation.uuid,
    name: conversation.name,
    created_at: conversation.created_at,
    updated_at: conversation.updated_at,
    message_count: conversation.chat_messages?.length ?? 0,
    projects_v2_uuid: conversation.projects_v2_uuid,
  };
  writeFileSync(join(chatDir, 'meta.json'), JSON.stringify(meta, null, 2));

  console.log(chatMdPath);
}

main().catch(err => {
  if (err instanceof ChatReaderError) {
    console.error(err.message);
    process.exit(err.exitCode);
  }
  console.error(`internal error: ${err.stack ?? err.message}`);
  process.exit(1);
});
