import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmod, mkdir, readdir, readFile, rm, stat } from 'node:fs/promises';
import { extname, relative, resolve, sep } from 'node:path';

export interface PackedFileRecord {
  path: string;
  byteLength: number;
  sha256: string;
}

export interface PackageAuditResult {
  files: PackedFileRecord[];
  executableMode: string;
  textFilesScanned: number;
  allowlistedFindings: Array<{ path: string; value: string }>;
}

const forbiddenPaths = [
  /^package\/(?:test|scripts|examples|\.tmp|\.soredemo)(?:\/|$)/,
  /(?:^|\/)\.env(?:\.|$)/,
  /(?:^|\/)\.npmrc$/,
  /(?:^|\/)node_modules(?:\/|$)/,
  /\.(?:map|mp4|jpg|jpeg|png|tgz|log|ts)$/i,
];

const textExtensions = new Set(['', '.js', '.json', '.md', '.svg', '.yaml', '.yml']);
const secretPatterns = [
  { label: 'home-directory path', pattern: /\/Users\//g },
  { label: 'Homebrew Cellar path', pattern: /\/opt\/homebrew\/Cellar\//g },
  { label: 'npm token', pattern: /npm_[A-Za-z0-9]{20,}/g },
  { label: 'authorization header', pattern: /authorization\s*:\s*(?:bearer|basic)\s+/gi },
  { label: 'cookie header', pattern: /(?:^|\n)cookie\s*:/gi },
];

async function run(file: string, args: string[]): Promise<void> {
  const child = spawn(file, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk: string) => {
    stderr = `${stderr}${chunk}`.slice(-64_000);
  });
  const code = await new Promise<number | null>((accept, reject) => {
    child.once('error', reject);
    child.once('close', accept);
  });
  if (code !== 0) throw new Error(`${file} ${args.join(' ')} failed (${code}): ${stderr}`);
}

async function files(directory: string): Promise<string[]> {
  const output: string[] = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) output.push(...(await files(path)));
    else if (entry.isFile()) output.push(path);
  }
  return output.sort();
}

function sha256(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex');
}

export async function auditTarball(
  tarball: string,
  extractionRoot: string,
): Promise<PackageAuditResult> {
  await rm(extractionRoot, { recursive: true, force: true });
  await mkdir(extractionRoot, { recursive: true });
  await run('tar', ['-xzf', tarball, '-C', extractionRoot]);
  const packageRoot = resolve(extractionRoot, 'package');
  const absoluteFiles = await files(packageRoot);
  const records: PackedFileRecord[] = [];
  const allowlistedFindings: PackageAuditResult['allowlistedFindings'] = [];
  let textFilesScanned = 0;
  for (const file of absoluteFiles) {
    const path = `package/${relative(packageRoot, file).split(sep).join('/')}`;
    if (forbiddenPaths.some((pattern) => pattern.test(path)))
      throw new Error(`Tarball contains forbidden file: ${path}`);
    const bytes = await readFile(file);
    records.push({ path, byteLength: bytes.byteLength, sha256: sha256(bytes) });
    if (!textExtensions.has(extname(path))) continue;
    textFilesScanned += 1;
    const text = bytes.toString('utf8');
    for (const rule of secretPatterns) {
      rule.pattern.lastIndex = 0;
      if (rule.pattern.test(text)) throw new Error(`${rule.label} found in ${path}`);
    }
    if (text.includes('.soredemo/runs')) {
      const allowed = path === 'package/dist/config/load.js';
      if (!allowed) throw new Error(`Unexpected run-workspace path found in ${path}`);
      allowlistedFindings.push({ path, value: '.soredemo/runs (runtime default)' });
    }
  }
  const cli = resolve(packageRoot, 'dist/cli.js');
  const cliStat = await stat(cli);
  if ((cliStat.mode & 0o111) === 0) {
    await chmod(cli, cliStat.mode | 0o755);
    throw new Error('Packed CLI entry is not executable');
  }
  const firstLine = (await readFile(cli, 'utf8')).split('\n')[0];
  if (firstLine !== '#!/usr/bin/env node') throw new Error('Packed CLI has an invalid shebang');
  const packageJson = JSON.parse(await readFile(resolve(packageRoot, 'package.json'), 'utf8')) as {
    bin?: Record<string, string>;
  };
  if (packageJson.bin?.soredemo !== './dist/cli.js')
    throw new Error('Packed bin mapping is invalid');
  return {
    files: records,
    executableMode: (cliStat.mode & 0o777).toString(8),
    textFilesScanned,
    allowlistedFindings,
  };
}
