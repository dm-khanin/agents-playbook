const LANG_EXT = {
  typescript: 'ts', javascript: 'js', python: 'py', go: 'go', rust: 'rs',
  java: 'java', ruby: 'rb', sql: 'sql', bash: 'sh', shell: 'sh',
  html: 'html', css: 'css', json: 'json', yaml: 'yml', markdown: 'md',
};

const TYPE_EXT = {
  'text/markdown': 'md',
  'text/html': 'html',
  'text/plain': 'txt',
  'image/svg+xml': 'svg',
  'application/vnd.ant.mermaid': 'mermaid',
  'application/vnd.ant.react': 'tsx',
};

export function slugify(input) {
  if (!input) return '';
  return String(input)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

export function extensionForArtifact(input) {
  if (input.type === 'application/vnd.ant.code') {
    return LANG_EXT[input.language] ?? 'txt';
  }
  return TYPE_EXT[input.type] ?? 'txt';
}

function applyUpdate(prevContent, input) {
  if (typeof input.old_str !== 'string' || typeof input.new_str !== 'string') {
    return prevContent;
  }
  return prevContent.replace(input.old_str, input.new_str);
}

export function reconstructArtifacts(conv) {
  const versions = new Map();
  const meta = new Map();
  for (const msg of conv.chat_messages ?? []) {
    for (const block of msg.content ?? []) {
      if (block.type !== 'tool_use' || block.name !== 'artifacts') continue;
      const input = block.input ?? {};
      const id = input.id;
      if (!id) continue;
      const list = versions.get(id) ?? [];
      let content;
      let malformed = false;
      if (input.command === 'create' || input.command === 'rewrite') {
        if (typeof input.content !== 'string') { content = ''; malformed = true; }
        else { content = input.content; }
      } else if (input.command === 'update') {
        const prev = list[list.length - 1]?.content ?? '';
        content = applyUpdate(prev, input);
      } else {
        continue;
      }
      if (input.command === 'create' && !meta.has(id)) {
        meta.set(id, { title: input.title, type: input.type, language: input.language });
      }
      list.push({ messageUuid: msg.uuid, content, malformed });
      versions.set(id, list);
    }
  }
  return Object.assign(versions, { meta });
}
