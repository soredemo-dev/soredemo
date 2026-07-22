import { spawn } from 'node:child_process';
import { rm } from 'node:fs/promises';
import { resolve } from 'node:path';
import { startFixtureServer } from '../test/fixtures/web-app/server.js';
import { verifyLiveWorkspace } from '../test/golden-tools/live-visual.js';
import { stableJson } from '../test/golden-tools/profile.js';

const outputRoot = resolve('.tmp/live-visual-authority');
const outputFile = resolve(outputRoot, 'rendered.mp4');
await rm(outputRoot, { recursive: true, force: true });
const server = await fixtureServer();
try {
  const rendered = await runPublicRender(outputFile);
  if (!rendered.success || !rendered.artifactsPath) {
    throw new Error('Public render did not return a preserved workspace');
  }
  const verification = await verifyLiveWorkspace(rendered.artifactsPath, outputFile);
  process.stdout.write(stableJson({ ...verification, renderResult: rendered }));
} finally {
  await server.close();
}

async function runPublicRender(output: string): Promise<PublicRenderResult> {
  const child = spawn(
    process.execPath,
    [
      resolve('dist/cli.js'),
      'render',
      'test/fixtures/full-demo.yaml',
      '--out',
      output,
      '--keep-artifacts',
      '--json',
    ],
    { stdio: ['ignore', 'pipe', 'pipe'] },
  );
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk: string) => {
    stdout += chunk;
    if (stdout.length > 1024 * 1024) throw new Error('Public render stdout exceeded limit');
  });
  child.stderr.on('data', (chunk: string) => {
    stderr = `${stderr}${chunk}`.slice(-1024 * 1024);
  });
  const exitCode = await new Promise<number | null>((resolveExit, reject) => {
    child.once('error', reject);
    child.once('close', resolveExit);
  });
  if (exitCode !== 0) {
    throw new Error(`Public render failed (${exitCode}): ${stderr}\n${stdout}`);
  }
  return JSON.parse(stdout) as PublicRenderResult;
}

interface PublicRenderResult {
  success: boolean;
  outputPath: string;
  outputBytes: number;
  outputSha256: string;
  durationSeconds: number;
  frameCount: number;
  artifactsPath?: string;
}

async function fixtureServer() {
  try {
    return await startFixtureServer(4173, resolve('test/fixtures/web-app'));
  } catch (error) {
    if (!isAddressInUse(error)) throw error;
    const response = await fetch('http://127.0.0.1:4173/');
    const body = await response.text();
    if (!response.ok || !body.includes('data-testid="demo-ready"')) {
      throw new Error('Port 4173 is occupied by something other than the Soredemo fixture');
    }
    return { url: 'http://127.0.0.1:4173', close: async () => undefined };
  }
}

function isAddressInUse(error: unknown): boolean {
  return (
    typeof error === 'object' &&
    error !== null &&
    'code' in error &&
    (error as { code?: unknown }).code === 'EADDRINUSE'
  );
}
