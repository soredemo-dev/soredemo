import { execFile } from 'node:child_process';
import { chmod, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { promisify } from 'node:util';
import { afterEach, describe, expect, it } from 'vitest';
import { auditTarball } from '../../scripts/release-package-audit.js';

const exec = promisify(execFile);
const roots: string[] = [];

async function fixture(
  extra: Record<string, string> = {},
): Promise<{ tarball: string; root: string }> {
  const root = await mkdtemp(resolve(tmpdir(), 'soredemo-package-audit-'));
  roots.push(root);
  const packageRoot = resolve(root, 'package');
  await mkdir(resolve(packageRoot, 'dist/config'), { recursive: true });
  await writeFile(
    resolve(packageRoot, 'package.json'),
    `${JSON.stringify({ bin: { soredemo: './dist/cli.js' } })}\n`,
  );
  await writeFile(resolve(packageRoot, 'dist/cli.js'), '#!/usr/bin/env node\n');
  await chmod(resolve(packageRoot, 'dist/cli.js'), 0o755);
  await writeFile(resolve(packageRoot, 'dist/config/load.js'), "const runs = '.soredemo/runs';\n");
  for (const [path, contents] of Object.entries(extra)) {
    const file = resolve(packageRoot, path);
    await mkdir(resolve(file, '..'), { recursive: true });
    await writeFile(file, contents);
  }
  const tarball = resolve(root, 'package.tgz');
  await exec('tar', ['-czf', tarball, '-C', root, 'package']);
  return { tarball, root };
}

describe('release package audit', () => {
  afterEach(async () => {
    await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
  });

  it('accepts the narrow runtime workspace default as an explicit allowlist entry', async () => {
    const value = await fixture();
    const result = await auditTarball(value.tarball, resolve(value.root, 'extract'));
    expect(result.executableMode).toBe('755');
    expect(result.allowlistedFindings).toEqual([
      { path: 'package/dist/config/load.js', value: '.soredemo/runs (runtime default)' },
    ]);
  });

  it('rejects absolute developer paths', async () => {
    const value = await fixture({ 'dist/leak.js': "const path = '/Users/developer/private';\n" });
    await expect(auditTarball(value.tarball, resolve(value.root, 'extract'))).rejects.toThrow(
      'home-directory path',
    );
  });

  it('rejects test and maintainer files', async () => {
    const value = await fixture({ 'scripts/release.js': 'export {};\n' });
    await expect(auditTarball(value.tarball, resolve(value.root, 'extract'))).rejects.toThrow(
      'forbidden file',
    );
  });
});
