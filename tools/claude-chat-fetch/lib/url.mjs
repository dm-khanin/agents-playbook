import { ChatReaderError } from './errors.mjs';

const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const CHAT_URL_RE = new RegExp(`^https://claude\\.ai/chat/(${UUID})(?:/.*)?(?:\\?.*)?$`);

export function parseChatUrl(url) {
  const match = CHAT_URL_RE.exec(url);
  if (!match) {
    throw new ChatReaderError(`not a claude.ai chat URL: ${url}`, 2);
  }
  return match[1];
}
