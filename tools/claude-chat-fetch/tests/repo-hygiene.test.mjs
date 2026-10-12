import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const toolDir = join(dirname(fileURLToPath(import.meta.url)), '..');

test('test_no_session_or_cache_tracked', () => {
  const tracked = execFileSync('git', ['ls-files', '.'], { cwd: toolDir, encoding: 'utf8' }).split('\n');
  assert.ok(tracked.length > 5, 'expected the tool files to be tracked');
  for (const file of tracked) {
    assert.doesNotMatch(file, /(^|\/)(\.session|cache\/|.*\.env$)/, file);
  }
});
