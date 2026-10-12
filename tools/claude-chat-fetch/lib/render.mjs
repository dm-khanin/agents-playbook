const SENDER_HEADERS = {
  human: '## 👤 Human',
  assistant: '## 🤖 Assistant',
};

function renderHeader(conv) {
  const created = conv.created_at?.slice(0, 10) ?? 'unknown';
  const updated = conv.updated_at?.slice(0, 10) ?? 'unknown';
  const count = conv.chat_messages?.length ?? 0;
  const project = conv.projects_v2_uuid ? ` · Project: ${conv.projects_v2_uuid}` : '';
  return `# ${conv.name ?? '(untitled)'}\n_Created: ${created} · Updated: ${updated} · ${count} messages${project}_\n\n---\n`;
}

function renderTextBlock(block) {
  return block.text ?? '';
}

function renderThinking(block) {
  const text = (block.thinking ?? '').split('\n').map(l => `> ${l}`).join('\n');
  return `> 💭 _thinking_\n${text}`;
}

const MAX_INLINE_STRING = 2000;
const MAX_TOOL_RESULT_LINES = 30;
const HEAD_LINES = 22;
const TAIL_LINES = 8;

function elideLongStrings(value) {
  if (typeof value === 'string') {
    return value.length > MAX_INLINE_STRING ? `<elided: ${value.length} chars>` : value;
  }
  if (Array.isArray(value)) return value.map(elideLongStrings);
  if (value !== null && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = elideLongStrings(v);
    return out;
  }
  return value;
}

function truncateLines(text) {
  const lines = text.split('\n');
  if (lines.length <= MAX_TOOL_RESULT_LINES) return text;
  const head = lines.slice(0, HEAD_LINES);
  const tail = lines.slice(-TAIL_LINES);
  const elided = lines.length - HEAD_LINES - TAIL_LINES;
  return `${head.join('\n')}\n... <${elided} lines elided>\n${tail.join('\n')}`;
}

function renderToolUse(block) {
  const name = block.name ?? 'unknown';
  const input = JSON.stringify(elideLongStrings(block.input ?? {}), null, 2);
  return `\`\`\`tool:${name}\n${input}\n\`\`\``;
}

function renderToolResult(block) {
  const text = (block.content ?? [])
    .map(c => c.type === 'text' ? c.text : '')
    .filter(Boolean)
    .join('\n');
  const truncated = truncateLines(text);
  return `\`\`\`tool_result\n${truncated}\n\`\`\``;
}

function renderBlock(block) {
  switch (block.type) {
    case 'text':        return renderTextBlock(block);
    case 'thinking':    return renderThinking(block);
    case 'tool_use':    return renderToolUse(block);
    case 'tool_result': return renderToolResult(block);
    default:            return '';
  }
}

function renderAttachments(entries) {
  if (!entries || entries.length === 0) return '';
  const real = entries.filter(e => e.kind !== 'pasted');
  const pasted = entries.filter(e => e.kind === 'pasted');
  const sections = [];
  if (real.length > 0) {
    const lines = ['📎 **Attachments:**'];
    for (const e of real) {
      if (e.tooLarge || e.unavailable) { lines.push(`- ${e.note}`); }
      else {
        const sizeStr = e.size ? ` (${e.kind}, ${Math.round(e.size / 1024)} KB)` : '';
        lines.push(`- [${e.name}](${e.localPath})${sizeStr}`);
      }
    }
    sections.push(lines.join('\n'));
  }
  if (pasted.length > 0) {
    const lines = ['📋 **Pasted text:**'];
    for (const e of pasted) {
      lines.push(`- [${e.name}](${e.localPath}) (${Math.round(e.size / 1024)} KB)`);
    }
    sections.push(lines.join('\n'));
  }
  return sections.join('\n\n');
}

function renderArtifactsSection(entries) {
  if (!entries || entries.length === 0) return '';
  const lines = [];
  for (const a of entries) {
    const versionsStr = a.versions.length > 0
      ? `\n_versions: ${a.versions.map((v, i) => `[v${i + 1}](${v})`).join(', ')}_`
      : '';
    const flag = a.malformed ? ' ⚠️ malformed' : '';
    lines.push(`🎨 **Artifact**: [${a.title}](${a.localPath})${flag}${versionsStr}`);
  }
  return lines.join('\n\n');
}

function renderCreatedFiles(entries) {
  if (!entries || entries.length === 0) return '';
  const lines = ['📄 **Created by Claude:**'];
  for (const e of entries) {
    lines.push(`- [${e.name}](${e.localPath}) (${Math.round(e.size / 1024)} KB)`);
  }
  return lines.join('\n');
}

function renderMessage(msg, manifest) {
  const header = SENDER_HEADERS[msg.sender] ?? `## ${msg.sender}`;
  const body = (msg.content ?? []).map(renderBlock).filter(Boolean).join('\n\n');
  const m = manifest.get(msg.uuid);
  const attachments = renderAttachments(m?.attachments);
  const artifacts = renderArtifactsSection(m?.artifacts);
  const created = renderCreatedFiles(m?.created);
  return [header, '', body, attachments, artifacts, created].filter(Boolean).join('\n\n');
}

function renderProjectDocs(manifest) {
  const entry = manifest.get('__project__');
  if (!entry || !entry.projectDocs || entry.projectDocs.length === 0) return '';
  const lines = ['## 📁 Project Knowledge'];
  for (const d of entry.projectDocs) {
    lines.push(`- [${d.name}](${d.localPath}) (${Math.round(d.size / 1024)} KB)`);
  }
  lines.push('---');
  return lines.join('\n');
}

export function renderConversation(conv, { attachmentManifest }) {
  const head = renderHeader(conv);
  const projectSection = renderProjectDocs(attachmentManifest);
  const body = (conv.chat_messages ?? []).map(m => renderMessage(m, attachmentManifest)).join('\n\n');
  return [head, projectSection, body].filter(Boolean).join('\n\n') + '\n';
}
