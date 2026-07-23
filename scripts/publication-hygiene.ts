import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer, type IncomingMessage } from 'node:http';
import { tmpdir } from 'node:os';
import { basename, resolve } from 'node:path';

export interface PublicationLeak {
  field: string;
  value: string;
  reason: string;
}

export interface PublicationPrivacyOptions {
  originalWorkspace?: string;
}

export interface CapturedPublication {
  requestPath: string;
  metadata: Record<string, unknown>;
  leaks: PublicationLeak[];
}

function decodedVariants(value: string): string[] {
  const variants = new Set([value, value.replaceAll('\\u002f', '/').replaceAll('\\u005c', '\\')]);
  let current = value;
  for (let index = 0; index < 3; index += 1) {
    try {
      current = decodeURIComponent(current);
      variants.add(current);
    } catch {
      break;
    }
  }
  return [...variants];
}

function reasonFor(value: string, options: PublicationPrivacyOptions): string | undefined {
  const normalized = value.replaceAll('\\', '/');
  if (/\/Users\/[^/]+/u.test(normalized)) return 'macOS user profile path';
  if (/\/home\/[^/]+/u.test(normalized)) return 'Linux user profile path';
  if (/[A-Za-z]:\/Users\/[^/]+/u.test(normalized)) return 'Windows user profile path';
  if (options.originalWorkspace) {
    const workspace = options.originalWorkspace.replaceAll('\\', '/');
    if (normalized.includes(workspace)) return 'original repository path';
  }
  if (/\.soredemo\/runs|capture\/frames|diagnostics\/error/u.test(normalized)) {
    return 'capture or diagnostic path';
  }
  if (/(?:npm|github|gh)[_-]?(?:token|auth)[=:][^\s]+/iu.test(value)) {
    return 'credential-like metadata';
  }
  return undefined;
}

export function publicationMetadataLeaks(
  metadata: unknown,
  options: PublicationPrivacyOptions = {},
): PublicationLeak[] {
  const leaks: PublicationLeak[] = [];
  const visit = (value: unknown, field: string): void => {
    if (typeof value === 'string') {
      for (const variant of decodedVariants(value)) {
        const reason = reasonFor(variant, options);
        if (reason) {
          leaks.push({ field, value, reason });
          break;
        }
      }
      return;
    }
    if (Array.isArray(value)) {
      value.forEach((item, index) => {
        visit(item, `${field}[${index}]`);
      });
      return;
    }
    if (value && typeof value === 'object') {
      for (const [key, item] of Object.entries(value)) {
        visit(item, field ? `${field}.${key}` : key);
      }
    }
  };
  visit(metadata, '');
  return leaks;
}

export function assertPublicationMetadataSafe(
  metadata: unknown,
  options: PublicationPrivacyOptions = {},
): void {
  const leaks = publicationMetadataLeaks(metadata, options);
  if (leaks.length > 0) {
    throw new Error(
      `Publication metadata contains private source data: ${leaks
        .map((leak) => `${leak.field} (${leak.reason})`)
        .join(', ')}`,
    );
  }
}

async function requestBody(request: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  let bytes = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    bytes += buffer.byteLength;
    if (bytes > 32 * 1024 * 1024) throw new Error('Mock registry request exceeded 32 MiB');
    chunks.push(buffer);
  }
  return Buffer.concat(chunks);
}

async function command(
  file: string,
  args: string[],
  options: { cwd: string; env: NodeJS.ProcessEnv },
): Promise<{ code: number | null; stdout: string; stderr: string }> {
  const child = spawn(file, args, {
    cwd: options.cwd,
    env: options.env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk: string) => {
    stdout = `${stdout}${chunk}`.slice(-1_000_000);
  });
  child.stderr.on('data', (chunk: string) => {
    stderr = `${stderr}${chunk}`.slice(-1_000_000);
  });
  const code = await new Promise<number | null>((accept, reject) => {
    child.once('error', reject);
    child.once('close', accept);
  });
  return { code, stdout, stderr };
}

export async function captureNpmPublication(options: {
  source: string;
  cwd: string;
  originalWorkspace?: string;
}): Promise<CapturedPublication> {
  let captured: { requestPath: string; metadata: Record<string, unknown> } | undefined;
  const server = createServer(async (request, response) => {
    try {
      if (request.method === 'PUT') {
        captured = {
          requestPath: request.url ?? '/',
          metadata: JSON.parse((await requestBody(request)).toString('utf8')) as Record<
            string,
            unknown
          >,
        };
        response.writeHead(201, { 'content-type': 'application/json' });
        response.end('{"ok":true}');
        return;
      }
      response.writeHead(404, { 'content-type': 'application/json' });
      response.end('{"error":"not found"}');
    } catch (error) {
      response.writeHead(400, { 'content-type': 'application/json' });
      response.end(
        JSON.stringify({ error: error instanceof Error ? error.message : String(error) }),
      );
    }
  });
  await new Promise<void>((accept, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', accept);
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Mock registry did not bind TCP');
  const registry = `http://127.0.0.1:${address.port}`;
  const root = await mkdtemp(resolve(tmpdir(), 'soredemo-npm-capture-'));
  const userConfig = resolve(root, 'npmrc');
  await writeFile(
    userConfig,
    `registry=${registry}/\n//127.0.0.1:${address.port}/:_authToken=loopback-test-token\n`,
  );
  try {
    const result = await command(
      'npm',
      [
        'publish',
        options.source,
        '--registry',
        registry,
        '--tag',
        'alpha',
        '--access',
        'public',
        '--ignore-scripts',
      ],
      {
        cwd: options.cwd,
        env: {
          ...process.env,
          npm_config_userconfig: userConfig,
          npm_config_cache: resolve(root, 'cache'),
          npm_config_loglevel: 'error',
        },
      },
    );
    if (result.code !== 0 || !captured) {
      throw new Error(
        `Mock npm publication failed (${result.code}): ${result.stderr || result.stdout || 'no output'}`,
      );
    }
    const publication = captured as {
      requestPath: string;
      metadata: Record<string, unknown>;
    };
    return {
      ...publication,
      leaks: publicationMetadataLeaks(publication.metadata, {
        ...(options.originalWorkspace ? { originalWorkspace: options.originalWorkspace } : {}),
      }),
    };
  } finally {
    await new Promise<void>((accept) => server.close(() => accept()));
    await rm(root, { recursive: true, force: true });
  }
}

export async function prepareNeutralPublicationDirectory(sourceDirectory: string): Promise<string> {
  const root = await mkdtemp(resolve(tmpdir(), 'soredemo-publication-stage-'));
  const target = resolve(root, 'package');
  await mkdir(target, { recursive: true });
  const packageJson = JSON.parse(
    await readFile(resolve(sourceDirectory, 'package.json'), 'utf8'),
  ) as Record<string, unknown>;
  await writeFile(
    resolve(target, 'package.json'),
    `${JSON.stringify({ ...packageJson, private: false }, null, 2)}\n`,
  );
  return target;
}

export function publicationSourceFields(
  metadata: Record<string, unknown>,
): Record<string, unknown> {
  const versions = metadata.versions as Record<string, Record<string, unknown>> | undefined;
  const version = versions ? Object.values(versions)[0] : undefined;
  if (!version) return {};
  return Object.fromEntries(
    ['_from', '_resolved', '_where', 'gitHead', 'dist'].flatMap((key) =>
      key in version ? [[key, version[key]]] : [],
    ),
  );
}

export function neutralStageLabel(directory: string): string {
  return basename(resolve(directory, '..'));
}
