import { spawn } from 'node:child_process';
import { access, cp, mkdir, readdir, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { startFixtureServer } from '../test/fixtures/web-app/server.js';
import { verifyLiveWorkspace } from '../test/golden-tools/live-visual.js';

interface RunResult {
  code: number | null;
  stdout: string;
  stderr: string;
}

async function run(
  file: string,
  args: string[],
  options: { cwd: string; env: NodeJS.ProcessEnv; stream?: boolean },
): Promise<RunResult> {
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
    stdout += chunk;
    if (options.stream) process.stdout.write(chunk);
  });
  child.stderr.on('data', (chunk: string) => {
    stderr = `${stderr}${chunk}`.slice(-1_000_000);
    if (options.stream) process.stderr.write(chunk);
  });
  const code = await new Promise<number | null>((accept, reject) => {
    child.once('error', reject);
    child.once('close', accept);
  });
  return { code, stdout, stderr };
}

function requireSuccess(result: RunResult, label: string): void {
  if (result.code !== 0) throw new Error(`${label} failed (${result.code}): ${result.stderr}`);
}

function json(result: RunResult): Record<string, unknown> {
  return JSON.parse(result.stdout) as Record<string, unknown>;
}

export async function runCleanBrowserCacheGate(tarball: string): Promise<Record<string, unknown>> {
  const root = resolve('.tmp/release clean install');
  const project = resolve(root, 'project with spaces');
  const browserCache = resolve(root, 'empty browser cache');
  await rm(root, { recursive: true, force: true });
  await mkdir(project, { recursive: true });
  await writeFile(
    resolve(project, 'package.json'),
    `${JSON.stringify({ name: 'soredemo-clean-install-gate', private: true }, null, 2)}\n`,
  );
  await cp('test/fixtures/full-demo.yaml', resolve(project, 'demo.yaml'));
  await cp('test/fixtures/missing-target-demo.yaml', resolve(project, 'missing-target.yaml'));
  await cp('test/fixtures/soredemo.config.yaml', resolve(project, 'soredemo.config.yaml'));
  const environment = {
    ...process.env,
    PLAYWRIGHT_BROWSERS_PATH: browserCache,
    npm_config_cache: resolve(root, 'npm cache'),
  };
  const install = await run('npm', ['install', '--save-dev', tarball], {
    cwd: project,
    env: environment,
    stream: true,
  });
  requireSuccess(install, 'tarball install');
  const installationEntries = await readdir(project);
  if (
    installationEntries.includes('.soredemo') ||
    installationEntries.some((item) => item.endsWith('.mp4'))
  )
    throw new Error('Package installation created a render workspace or media file');
  const npx = (args: string[], stream = false) =>
    run('npx', ['--no-install', ...args], { cwd: project, env: environment, stream });
  const version = await npx(['soredemo', '--version']);
  requireSuccess(version, 'packed version');
  const help = await npx(['soredemo', '--help']);
  requireSuccess(help, 'packed help');
  const missingDoctor = await npx(['soredemo', 'doctor', '--json']);
  if (missingDoctor.code !== 1) throw new Error('Doctor did not fail for an empty browser cache');
  const missingDoctorJson = json(missingDoctor);
  const chromiumCheck = (missingDoctorJson.checks as Array<Record<string, unknown>>).find(
    (check) => check.name === 'chromium',
  );
  if (
    chromiumCheck?.available !== false ||
    JSON.stringify(chromiumCheck).includes('npx playwright install chromium') === false
  )
    throw new Error('Missing-browser doctor output is not actionable');
  const browserInstall = await npx(['playwright', 'install', 'chromium'], true);
  requireSuccess(browserInstall, 'isolated Chromium install');
  const doctor = await npx(['soredemo', 'doctor', '--json']);
  requireSuccess(doctor, 'packed doctor');
  const validate = await npx(['soredemo', 'validate', 'demo.yaml']);
  requireSuccess(validate, 'packed validate');
  const server = await fixtureServer();
  try {
    const render = await npx([
      'soredemo',
      'render',
      'demo.yaml',
      '--out',
      'rendered.mp4',
      '--keep-artifacts',
      '--json',
    ]);
    requireSuccess(render, 'packed render');
    const renderJson = json(render);
    const output = resolve(project, 'rendered.mp4');
    await access(output);
    const liveVerification = await verifyLiveWorkspace(String(renderJson.artifactsPath), output);
    const failed = await npx([
      'soredemo',
      'render',
      'missing-target.yaml',
      '--out',
      'should-not-exist.mp4',
      '--json',
    ]);
    if (failed.code !== 1 || json(failed).code !== 'TARGET_NOT_FOUND')
      throw new Error(`Packed missing-target failure was unstable: ${failed.stdout}`);
    await access(resolve(project, 'should-not-exist.mp4')).then(
      () => {
        throw new Error('Failed packed render created a final output');
      },
      () => undefined,
    );
    const partials = (await recursiveFiles(project)).filter((file) =>
      file.endsWith('.partial.mp4'),
    );
    if (partials.length > 0) throw new Error('Failed packed render left a partial MP4');
    return {
      project,
      browserCache,
      packageVersion: version.stdout.trim(),
      helpVerified: help.stdout.includes('Soredemo public alpha'),
      missingBrowser: chromiumCheck,
      doctor: json(doctor),
      render: renderJson,
      liveVerification,
      failedRender: json(failed),
    };
  } finally {
    await server.close();
  }
}

async function fixtureServer(): Promise<{ close(): Promise<void> }> {
  try {
    return await startFixtureServer(4173, resolve('test/fixtures/web-app'));
  } catch (error) {
    if (
      typeof error !== 'object' ||
      error === null ||
      !('code' in error) ||
      (error as { code?: unknown }).code !== 'EADDRINUSE'
    )
      throw error;
    const response = await fetch('http://127.0.0.1:4173/');
    const body = await response.text();
    if (!response.ok || !body.includes('data-testid="demo-ready"'))
      throw new Error('Port 4173 is occupied by something other than the Soredemo fixture');
    return { close: async () => undefined };
  }
}

async function recursiveFiles(directory: string): Promise<string[]> {
  const output: string[] = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) output.push(...(await recursiveFiles(path)));
    else if (entry.isFile()) output.push(path);
  }
  return output;
}

if (process.argv[1]?.endsWith('clean-browser-cache-gate.js')) {
  const tarball = process.argv[2];
  if (!tarball) throw new Error('Tarball path is required');
  const result = await runCleanBrowserCacheGate(resolve(tarball));
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}
