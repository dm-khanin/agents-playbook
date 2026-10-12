import { homedir } from 'node:os';
import { join } from 'node:path';

export function sessionPath(env = process.env) {
  if (env.CLAUDE_CHAT_FETCH_SESSION) return env.CLAUDE_CHAT_FETCH_SESSION;
  return join(env.XDG_CONFIG_HOME || join(homedir(), '.config'), 'claude-chat-fetch', 'session');
}

export function cacheDir(env = process.env) {
  if (env.CLAUDE_CHAT_FETCH_CACHE) return env.CLAUDE_CHAT_FETCH_CACHE;
  return join(env.XDG_CACHE_HOME || join(homedir(), '.cache'), 'claude-chat-fetch');
}
