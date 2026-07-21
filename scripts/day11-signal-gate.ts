import { spawn } from 'node:child_process';
import { access, readdir, readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { setTimeout } from 'node:timers/promises';

const runsRoot = resolve('test/fixtures/.soredemo/runs');
const outputRoot = resolve('.tmp/day11-signals');

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  const before = new Set(await readdir(runsRoot).catch(() => []));
  const output = resolve(outputRoot, `${signal.toLowerCase()}.mp4`);
  const child = spawn(
    process.execPath,
    [resolve('dist/cli.js'), 'render', 'test/fixtures/full-demo.yaml', '--out', output, '--json'],
    { cwd: process.cwd(), env: process.env, stdio: ['ignore', 'pipe', 'pipe'] },
  );
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => {
    stdout += String(chunk);
  });
  child.stderr.on('data', (chunk) => {
    stderr += String(chunk);
  });
  const resultPromise = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>(
    (resolveResult, reject) => {
      child.once('error', reject);
      child.once('close', (code, childSignal) => resolveResult({ code, signal: childSignal }));
    },
  );
  const workspace = await waitForCapturingWorkspace(before);
  child.kill(signal);
  const result = await resultPromise;
  const manifest = JSON.parse(
    await readFile(resolve(runsRoot, workspace, 'run-manifest.json'), 'utf8'),
  ) as { status: string; stages: Array<{ status: string }> };
  if (
    result.code === 0 ||
    manifest.status !== 'aborted' ||
    manifest.stages.some((stage) => stage.status === 'running')
  ) {
    throw new Error(
      `${signal} cleanup failed: ${JSON.stringify({ result, manifest, stdout, stderr })}`,
    );
  }
  await access(output).then(
    () => {
      throw new Error(`${signal} left a final output`);
    },
    () => undefined,
  );
  const partials = (await recursiveFiles(resolve(runsRoot, workspace))).filter((file) =>
    file.endsWith('.partial.mp4'),
  );
  if (partials.length > 0) throw new Error(`${signal} left partial outputs`);
  process.stdout.write(
    `${JSON.stringify({ signal, passed: true, exitCode: result.code, workspace: resolve(runsRoot, workspace) })}\n`,
  );
}

async function waitForCapturingWorkspace(before: Set<string>): Promise<string> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const candidates = (await readdir(runsRoot).catch(() => [])).filter(
      (directory) => !before.has(directory),
    );
    for (const directory of candidates) {
      try {
        const manifest = JSON.parse(
          await readFile(resolve(runsRoot, directory, 'run-manifest.json'), 'utf8'),
        ) as { status: string };
        if (manifest.status === 'capturing') return directory;
      } catch {}
    }
    await setTimeout(50);
  }
  throw new Error('Timed out waiting for a capturing render workspace');
}

async function recursiveFiles(directory: string): Promise<string[]> {
  const output: string[] = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const file = resolve(directory, entry.name);
    if (entry.isDirectory()) output.push(...(await recursiveFiles(file)));
    else output.push(file);
  }
  return output;
}
