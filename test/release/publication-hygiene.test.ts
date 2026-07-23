import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { relative, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import {
  assertPublicationMetadataSafe,
  captureNpmPublication,
  prepareNeutralPublicationDirectory,
  publicationMetadataLeaks,
  publicationSourceFields,
} from '../../scripts/publication-hygiene.js';

const roots: string[] = [];

async function command(
  file: string,
  args: string[],
  cwd: string,
  env: NodeJS.ProcessEnv = process.env,
): Promise<void> {
  const child = spawn(file, args, { cwd, env, stdio: ['ignore', 'ignore', 'pipe'] });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk: string) => {
    stderr += chunk;
  });
  const code = await new Promise<number | null>((accept, reject) => {
    child.once('error', reject);
    child.once('close', accept);
  });
  if (code !== 0) throw new Error(`${file} failed (${code}): ${stderr}`);
}

async function fixture(): Promise<{ root: string; packageDirectory: string; tarball: string }> {
  const root = await mkdtemp(resolve(tmpdir(), 'soredemo hygiene user-'));
  roots.push(root);
  const packageDirectory = resolve(root, 'private repository', 'package');
  await mkdir(packageDirectory, { recursive: true });
  await writeFile(
    resolve(packageDirectory, 'package.json'),
    `${JSON.stringify(
      {
        name: `soredemo-publication-fixture-${process.pid}`,
        version: '0.0.0-test.0',
        description: 'Loopback-only publication fixture',
        license: 'MIT',
      },
      null,
      2,
    )}\n`,
  );
  await writeFile(resolve(packageDirectory, 'index.js'), 'export const fixture = true;\n');
  await command('npm', ['pack', '--silent', '--pack-destination', root], packageDirectory, {
    ...process.env,
    npm_config_cache: resolve(root, '.npm-cache'),
  });
  const tarball = resolve(
    root,
    `${`soredemo-publication-fixture-${process.pid}`}-0.0.0-test.0.tgz`,
  );
  await readFile(tarball);
  return { root, packageDirectory, tarball };
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe.sequential('publication metadata hygiene', () => {
  it('captures risky absolute and relative tarball source metadata', async () => {
    const sample = await fixture();
    const absolute = await captureNpmPublication({
      source: sample.tarball,
      cwd: sample.packageDirectory,
      originalWorkspace: sample.root,
    });
    const relativeSource = relative(sample.packageDirectory, sample.tarball);
    const relativePublication = await captureNpmPublication({
      source: relativeSource,
      cwd: sample.packageDirectory,
      originalWorkspace: sample.root,
    });
    expect(publicationSourceFields(absolute.metadata)).toHaveProperty('_resolved');
    expect(publicationSourceFields(relativePublication.metadata)).toHaveProperty('_from');
    expect(absolute.leaks.length).toBeGreaterThan(0);
  }, 30_000);

  it('captures prepared-directory and neutral-stage publication safely', async () => {
    const sample = await fixture();
    const prepared = await captureNpmPublication({
      source: sample.packageDirectory,
      cwd: sample.root,
      originalWorkspace: sample.root,
    });
    expect(prepared.leaks).toEqual([]);
    expect(publicationSourceFields(prepared.metadata)).not.toHaveProperty('_resolved');

    const neutral = await prepareNeutralPublicationDirectory(sample.packageDirectory);
    roots.push(resolve(neutral, '..'));
    await writeFile(resolve(neutral, 'index.js'), 'export const fixture = true;\n');
    const captured = await captureNpmPublication({
      source: neutral,
      cwd: resolve(neutral, '..'),
      originalWorkspace: sample.root,
    });
    expect(captured.leaks).toEqual([]);
    expect(() =>
      assertPublicationMetadataSafe(captured.metadata, { originalWorkspace: sample.root }),
    ).not.toThrow();
  }, 30_000);

  it.each([
    '/Users/private-name/project/package.tgz',
    '/home/private-name/project/package.tgz',
    'C:\\Users\\private-name\\project\\package.tgz',
    '%2FUsers%2Fprivate-name%2Fproject',
    '\\u002fUsers\\u002fprivate-name\\u002fproject',
  ])('rejects private path representation %s', (value) => {
    expect(publicationMetadataLeaks({ _resolved: value })).toHaveLength(1);
    expect(() => assertPublicationMetadataSafe({ _resolved: value })).toThrow(
      'Publication metadata contains private source data',
    );
  });

  it('keeps the released alpha.0 candidate immutable', async () => {
    const candidate = await readFile('.tmp/release-candidate/SHA256SUMS', 'utf8');
    expect(candidate).toContain('443ef8a9f5434fb5e24bd8256e3823f58c18c81c5c4bfa8b3dc5a79f2665ef96');
  });
});
