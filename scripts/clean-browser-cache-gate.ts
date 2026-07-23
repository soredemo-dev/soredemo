import { spawn } from 'node:child_process';
import { access, cp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { load } from 'js-yaml';
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

interface PackedStudioHandle {
  url: string;
  close(): Promise<void>;
}

interface PackedStudioModule {
  startStudioServer(options: Record<string, unknown>): Promise<PackedStudioHandle>;
}

async function runPackedStudioGate(
  project: string,
  npx: (args: string[], stream?: boolean) => Promise<RunResult>,
): Promise<Record<string, unknown>> {
  const installedServer = resolve(project, 'node_modules/soredemo/dist/studio/server.js');
  const studioModule = (await import(pathToFileURL(installedServer).href)) as PackedStudioModule;
  const plan = load(await readFile('test/fixtures/full-demo.yaml', 'utf8')) as Record<
    string,
    unknown
  >;
  let proposed = false;
  const fakeProvider = {
    id: 'packed-fake-agent',
    displayName: 'Packed acceptance Agent',
    async checkAvailability() {
      return {
        available: true,
        version: '1.0.0-test',
        capabilities: ['structured-proposals', 'read-only'],
      };
    },
    async *proposePlan(request: { conversationId: string }) {
      proposed = true;
      yield { type: 'agent.started', conversationId: request.conversationId };
      yield {
        type: 'agent.proposal',
        proposal: {
          schemaVersion: 1,
          title: 'Packed Studio verified demo',
          summary: 'Exercises Chat, approval, production capture, proof, and output.',
          assumptions: ['The deterministic fixture is already running.'],
          plan,
          unresolved: [],
          warnings: [],
        },
      };
    },
    async *revisePlan(request: { conversationId: string }) {
      yield* this.proposePlan(request);
    },
    async cancel() {},
  };
  const studio = await studioModule.startStudioServer({
    projectRoot: project,
    host: '127.0.0.1',
    port: 0,
    agentProvider: fakeProvider,
  });
  try {
    const page = await fetch(studio.url);
    if (!page.ok) throw new Error(`Packed Studio page failed: ${page.status}`);
    const cookie = page.headers.get('set-cookie')?.split(';', 1)[0];
    if (!cookie) throw new Error('Packed Studio did not set its session cookie');
    const request = async (
      path: string,
      options: { method?: string; body?: Record<string, unknown> } = {},
    ): Promise<Record<string, unknown>> => {
      const response = await fetch(`${studio.url}${path}`, {
        method: options.method ?? 'GET',
        headers: {
          cookie,
          ...(options.method && options.method !== 'GET'
            ? { origin: studio.url, 'content-type': 'application/json' }
            : {}),
        },
        ...(options.body ? { body: JSON.stringify(options.body) } : {}),
      });
      const value = (await response.json()) as Record<string, unknown>;
      if (!response.ok)
        throw new Error(
          `Packed Studio ${path} failed (${response.status}): ${JSON.stringify(value)}`,
        );
      return value;
    };
    const meta = await request('/api/meta');
    const plans = await request('/api/plans');
    const conversationId = '00000000-0000-4000-8000-000000000015';
    const proposedPlan = await request('/api/agent/propose', {
      method: 'POST',
      body: {
        conversationId,
        featureRequest: 'Demonstrate the deterministic project creation flow.',
        initialUrl: 'http://127.0.0.1:4173',
        consent: {
          sourceFiles: false,
          semanticSnapshot: false,
          existingPlansAndTests: false,
        },
      },
    });
    if (!proposed) throw new Error('Packed Studio did not invoke the configured Agent provider');
    const planPath = 'demos/packed-studio.yaml';
    const approval = await request('/api/plans/approve', {
      method: 'POST',
      body: {
        conversationId,
        planHash: proposedPlan.planHash,
        path: planPath,
      },
    });
    const run = await request('/api/runs', {
      method: 'POST',
      body: {
        approved: true,
        planPath,
        outputPath: 'studio-rendered.mp4',
        proofPath: 'studio-rendered.proof',
      },
    });
    const runId = String(run.runId);
    const events = await collectStudioEvents(studio.url, cookie, runId);
    const snapshot = await request(`/api/runs/${runId}`);
    if (snapshot.state !== 'completed')
      throw new Error(`Packed Studio run did not complete: ${JSON.stringify(snapshot)}`);
    const sequences = events.map((event) => Number(event.sequence));
    for (let index = 1; index < sequences.length; index += 1) {
      const previous = sequences[index - 1];
      const current = sequences[index];
      if (previous === undefined || current === undefined || current <= previous)
        throw new Error('Packed Studio events were not strictly ordered');
    }
    const eventTypes = events.map((event) => String(event.type));
    for (const required of [
      'action.started',
      'capture.preview',
      'capture.metrics',
      'cursor.landing',
      'target.pixelProof',
      'proof.completed',
      'artifact.created',
      'run.completed',
    ]) {
      if (!eventTypes.includes(required))
        throw new Error(`Packed Studio event stream missed ${required}`);
    }
    const actionEvents = eventTypes.filter((type) => type === 'action.completed').length;
    if (actionEvents !== 10)
      throw new Error(`Packed Studio completed ${actionEvents} actions instead of 10`);
    const video = resolve(project, 'studio-rendered.mp4');
    const proof = resolve(project, 'studio-rendered.proof');
    await Promise.all([access(video), access(resolve(proof, 'manifest.json'))]);
    const proofVerification = await npx(['soredemo', 'proof', 'verify', proof, '--json']);
    requireSuccess(proofVerification, 'packed Studio proof');
    const [videoArtifact, proofArtifact] = await Promise.all([
      retryFetch(`${studio.url}/api/artifacts/${runId}-video`, cookie),
      retryFetch(`${studio.url}/api/artifacts/${runId}-proof`, cookie),
    ]);
    if (videoArtifact.headers.get('content-type') !== 'video/mp4')
      throw new Error('Packed Studio video artifact MIME changed');
    if (!proofArtifact.headers.get('content-type')?.startsWith('application/json'))
      throw new Error('Packed Studio proof artifact MIME changed');
    return {
      meta,
      discoveredPlanCount: Array.isArray(plans.plans) ? plans.plans.length : 0,
      proposal: {
        title: (proposedPlan.proposal as Record<string, unknown>).title,
        planHash: proposedPlan.planHash,
      },
      approval,
      runId,
      state: snapshot.state,
      eventCount: events.length,
      actionEvents,
      previewEvents: eventTypes.filter((type) => type === 'capture.preview').length,
      eventTypes: [...new Set(eventTypes)],
      proof: json(proofVerification),
      video,
    };
  } finally {
    await studio.close();
  }
}

async function collectStudioEvents(
  url: string,
  cookie: string,
  runId: string,
): Promise<Array<Record<string, unknown>>> {
  const abort = new AbortController();
  const timeout = setTimeout(() => abort.abort(), 240_000);
  try {
    const response = await fetch(`${url}/api/runs/${runId}/events`, {
      headers: { cookie },
      signal: abort.signal,
    });
    if (!response.ok || !response.body)
      throw new Error(`Packed Studio SSE failed: ${response.status}`);
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    const events: Array<Record<string, unknown>> = [];
    let pending = '';
    for (;;) {
      const next = await reader.read();
      if (next.done) break;
      pending += decoder.decode(next.value, { stream: true });
      let boundary = pending.indexOf('\n\n');
      while (boundary >= 0) {
        const block = pending.slice(0, boundary);
        pending = pending.slice(boundary + 2);
        const line = block.split('\n').find((candidate) => candidate.startsWith('data: '));
        if (line) {
          const event = JSON.parse(line.slice('data: '.length)) as Record<string, unknown>;
          events.push(event);
          if (['run.completed', 'run.failed', 'run.stopped'].includes(String(event.type))) {
            await reader.cancel();
            return events;
          }
        }
        boundary = pending.indexOf('\n\n');
      }
    }
    throw new Error('Packed Studio SSE ended without a terminal event');
  } finally {
    clearTimeout(timeout);
  }
}

async function retryFetch(url: string, cookie: string): Promise<Response> {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const response = await fetch(url, { headers: { cookie } });
    if (response.ok) return response;
    await new Promise((accept) => setTimeout(accept, 100));
  }
  throw new Error(`Packed Studio artifact was not registered: ${url}`);
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
    const packedStudio = await runPackedStudioGate(project, npx);
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
      packedStudio,
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
