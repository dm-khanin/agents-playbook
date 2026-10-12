import { mkdirSync, writeFileSync } from 'node:fs';
import { join, extname, basename } from 'node:path';
import { reconstructArtifacts, slugify, extensionForArtifact } from './artifacts.mjs';

const MAX_FILE_BYTES = 50 * 1024 * 1024;

function uniquePath(baseName, used) {
  if (!used.has(baseName)) {
    used.add(baseName);
    return baseName;
  }
  const ext = extname(baseName);
  const stem = baseName.slice(0, baseName.length - ext.length);
  let n = 1;
  while (used.has(`${stem}-${n}${ext}`)) n++;
  const next = `${stem}-${n}${ext}`;
  used.add(next);
  return next;
}

function fileUrl(orgUuid, fileUuid) {
  return `https://claude.ai/api/${orgUuid}/files/${fileUuid}/contents`;
}

function formatMb(bytes) {
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function writeArtifacts({ conversation, manifest, cacheDir }) {
  const versions = reconstructArtifacts(conversation);
  const filesDir = join(cacheDir, 'files');
  mkdirSync(filesDir, { recursive: true });

  for (const [id, list] of versions) {
    if (id === 'meta') continue;
    const m = versions.meta?.get(id) ?? {};
    const slug = slugify(m.title) || id;
    const ext = extensionForArtifact(m);
    const finalName = `artifact-${slug}.${ext}`;
    const finalContent = list[list.length - 1].content;
    writeFileSync(join(filesDir, finalName), finalContent);

    const versionNames = [];
    if (list.length > 1) {
      list.forEach((v, idx) => {
        const vName = `artifact-${slug}.v${idx + 1}.${ext}`;
        writeFileSync(join(filesDir, vName), v.content);
        versionNames.push(vName);
      });
    }

    const ownerMsg = list[list.length - 1].messageUuid;
    const existing = manifest.get(ownerMsg) ?? { attachments: [] };
    existing.artifacts = existing.artifacts ?? [];
    existing.artifacts.push({
      title: m.title ?? id,
      localPath: `files/${finalName}`,
      versions: versionNames.map(n => `files/${n}`),
      malformed: list.some(v => v.malformed),
    });
    manifest.set(ownerMsg, existing);
  }
}

export async function processAttachments({ conversation, api, orgUuid, cacheDir }) {
  const filesDir = join(cacheDir, 'files');
  mkdirSync(filesDir, { recursive: true });
  const usedNames = new Set();
  const manifest = new Map();

  for (const msg of conversation.chat_messages ?? []) {
    const entries = [];
    let pastedCounter = 0;
    for (const a of msg.attachments ?? []) {
      if (typeof a.extracted_content !== 'string') continue;
      pastedCounter++;
      const ext = (a.file_type || 'txt').replace(/^\./, '');
      const baseName = `pasted-${pastedCounter}.${ext}`;
      const safeName = uniquePath(baseName, usedNames);
      const localPath = `files/${safeName}`;
      writeFileSync(join(cacheDir, localPath), a.extracted_content);
      entries.push({
        localPath,
        name: a.file_name ?? safeName,
        kind: 'pasted',
        size: Buffer.byteLength(a.extracted_content, 'utf8'),
      });
    }
    const fetchables = [
      ...(msg.files_v2 ?? []).map(f => ({
        file_name: f.file_name,
        file_kind: f.file_kind,
        file_size: f.file_size,
        url: fileUrl(orgUuid, f.file_uuid),
      })),
      ...(msg.files ?? []).map(f => ({
        file_name: f.file_name,
        file_kind: f.file_kind,
        file_size: undefined,
        url: f.preview_url ? `https://claude.ai${f.preview_url}` : fileUrl(orgUuid, f.file_uuid),
      })),
    ];
    for (const f of fetchables) {
      const safeName = uniquePath(basename(f.file_name || 'file'), usedNames);
      const localPath = `files/${safeName}`;
      const entry = {
        localPath,
        name: f.file_name,
        kind: f.file_kind,
        size: f.file_size,
      };
      if ((f.file_size ?? 0) > MAX_FILE_BYTES) {
        entry.tooLarge = true;
        entry.note = `[file too large: ${f.file_name}, ${formatMb(f.file_size)} — fetch manually]`;
        usedNames.delete(safeName);
      } else {
        try {
          const buf = await api.getBinary(f.url);
          writeFileSync(join(cacheDir, localPath), Buffer.from(buf));
          if (entry.size === undefined) entry.size = buf.byteLength;
        } catch (err) {
          entry.unavailable = true;
          entry.note = `[file unavailable: ${f.file_name}]`;
          usedNames.delete(safeName);
        }
      }
      entries.push(entry);
    }
    const created = [];
    for (const block of msg.content ?? []) {
      if (block.type !== 'tool_use' || block.name !== 'create_file') continue;
      const input = block.input ?? {};
      if (typeof input.file_text !== 'string') continue;
      const rawName = basename(input.path || `created-${created.length + 1}.txt`);
      const safeName = uniquePath(rawName, usedNames);
      const localPath = `files/${safeName}`;
      writeFileSync(join(cacheDir, localPath), input.file_text);
      created.push({
        localPath,
        name: rawName,
        size: Buffer.byteLength(input.file_text, 'utf8'),
      });
    }
    if (entries.length > 0 || created.length > 0) {
      const existing = manifest.get(msg.uuid) ?? { attachments: [] };
      existing.attachments = entries.length > 0 ? entries : existing.attachments;
      if (created.length > 0) existing.created = created;
      manifest.set(msg.uuid, existing);
    }
  }
  if (conversation.projects_v2_uuid) {
    try {
      const docs = await api.getJson(
        `https://claude.ai/api/organizations/${orgUuid}/projects/${conversation.projects_v2_uuid}/docs`
      );
      const projectDocs = [];
      for (const d of docs ?? []) {
        const safeName = uniquePath(`project-${basename(d.file_name || d.uuid)}`, usedNames);
        const localPath = `files/${safeName}`;
        writeFileSync(join(cacheDir, localPath), d.content ?? '');
        projectDocs.push({
          localPath,
          name: d.file_name ?? d.uuid,
          size: Buffer.byteLength(d.content ?? '', 'utf8'),
        });
      }
      if (projectDocs.length > 0) {
        manifest.set('__project__', { projectDocs });
      }
    } catch (err) {
      console.error(`[warn] failed to fetch project docs: ${err.message}`);
    }
  }
  writeArtifacts({ conversation, manifest, cacheDir });
  return manifest;
}
