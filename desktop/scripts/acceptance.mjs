// Day-17 Electron acceptance harness (development only; never shipped).
// Boots the fixture web app, launches the real Electron shell against a temp
// project, and drives the FULL vertical slice through the Electron-hosted
// loopback Studio server over HTTP — exactly the endpoints the renderer calls.
// Covers checks 3 (vertical slice), 4 (missing target), 5 (quit during run).
import { spawn } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';

const desktopRoot = resolve(import.meta.dirname, '..');
const repoRoot = resolve(desktopRoot, '..');
const electronBin = resolve(desktopRoot, 'node_modules/.bin/electron');
const FIXTURE_PORT = 4173;

// The fixture web app is TypeScript; the repo's scripts build compiles it to
// .tmp/day2-build/. Run `pnpm exec tsc -p tsconfig.scripts.json` at the repo
// root first (release:check does this too).
const { startFixtureServer } = await import(
  pathToFileURL(resolve(repoRoot, '.tmp/day2-build/test/fixtures/web-app/server.js')).href
);

async function setupProject() {
  const project = await mkdtemp(resolve(tmpdir(), 'sd-desktop-accept-'));
  await mkdir(resolve(project, 'demos'), { recursive: true });
  await cp(resolve(repoRoot, 'test/fixtures/full-demo.yaml'), resolve(project, 'demo.yaml'));
  await cp(
    resolve(repoRoot, 'test/fixtures/missing-target-demo.yaml'),
    resolve(project, 'missing-target.yaml'),
  );
  await cp(
    resolve(repoRoot, 'test/fixtures/soredemo.config.yaml'),
    resolve(project, 'soredemo.config.yaml'),
  );
  return project;
}

function launchElectron(project, urlFile) {
  const child = spawn(electronBin, ['.'], {
    cwd: desktopRoot,
    env: {
      ...process.env,
      SOREDEMO_DESKTOP_PROJECT: project,
      SOREDEMO_DESKTOP_URL_FILE: urlFile,
      SOREDEMO_DESKTOP_AGENT: 'none',
      SOREDEMO_DESKTOP_HIDE_WINDOW: '1',
      SOREDEMO_DESKTOP_DIAG: '1',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', () => {});
  child.stderr.on('data', () => {});
  return child;
}

async function waitForUrl(urlFile) {
  for (let i = 0; i < 120; i += 1) {
    try {
      const text = (await readFile(urlFile, 'utf8')).trim();
      if (text) return text;
    } catch {}
    await delay(250);
  }
  throw new Error('timed out waiting for studio URL file');
}

async function session(base) {
  const page = await fetch(base);
  const cookie = (page.headers.get('set-cookie') ?? '').split(';')[0];
  const call = (path, options = {}) =>
    fetch(`${base}${path}`, {
      ...options,
      headers: {
        cookie,
        ...(options.body ? { origin: base, 'content-type': 'application/json' } : {}),
        ...(options.headers ?? {}),
      },
    });
  return { cookie, call };
}

async function drive(base, { plan, out, proof }) {
  const { call } = await session(base);
  const approve = await (
    await call('/api/plans/existing/approve', {
      method: 'POST',
      body: JSON.stringify({ path: plan }),
    })
  ).json();
  if (!approve.approved) throw new Error(`approval failed: ${JSON.stringify(approve)}`);
  const started = await (
    await call('/api/runs', {
      method: 'POST',
      body: JSON.stringify({ approved: true, planPath: plan, outputPath: out, proofPath: proof }),
    })
  ).json();
  const runId = started.runId;
  if (!runId) throw new Error(`run did not start: ${JSON.stringify(started)}`);
  // Collect ordered SSE events in the background.
  const events = [];
  const controller = new AbortController();
  const sse = call(`/api/runs/${runId}/events`, { signal: controller.signal })
    .then(async (response) => {
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        for (const chunk of buffer.split('\n\n')) {
          const m = chunk.match(/^event: (.+)$/mu);
          if (m) events.push(m[1]);
        }
        buffer = buffer.slice(buffer.lastIndexOf('\n\n') + 2);
      }
    })
    .catch(() => {});
  let snapshot;
  for (let i = 0; i < 600; i += 1) {
    snapshot = await (await call(`/api/runs/${runId}`)).json();
    if (['completed', 'failed', 'stopped'].includes(snapshot.state)) break;
    await delay(250);
  }
  controller.abort();
  await sse;
  return { runId, snapshot, events };
}

async function waitUntilCapturing(base, runId) {
  const { call } = await session(base);
  for (let i = 0; i < 240; i += 1) {
    const snapshot = await (await call(`/api/runs/${runId}`)).json();
    if (snapshot.state === 'capturing' || snapshot.completedActions > 0) return true;
    if (['failed', 'stopped', 'completed'].includes(snapshot.state)) return false;
    await delay(200);
  }
  return false;
}

function pids(pattern) {
  return new Promise((res) => {
    const ps = spawn('bash', ['-lc', `pgrep -f ${JSON.stringify(pattern)} || true`]);
    let out = '';
    ps.stdout.on('data', (c) => (out += String(c)));
    ps.on('close', () =>
      res(
        out
          .split('\n')
          .map((s) => Number(s.trim()))
          .filter((n) => Number.isInteger(n) && n > 0),
      ),
    );
  });
}

// Chromium/FFmpeg processes launched by a live render (Playwright's pinned
// Chromium build and the encoder's external ffmpeg).
const RENDER_PROCESS_PATTERN = 'chromium-1228|chrome-mac|ms-playwright|ffmpeg -';

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

const results = {};
const fixture = await startFixtureServer(FIXTURE_PORT, resolve(repoRoot, 'test/fixtures/web-app'));
try {
  // ---- Checks 3: full vertical slice inside the Electron-hosted server ----
  {
    const project = await setupProject();
    const urlFile = resolve(project, 'studio-url.txt');
    const child = launchElectron(project, urlFile);
    try {
      const base = await waitForUrl(urlFile);
      const { snapshot, events } = await drive(base, {
        plan: 'demo.yaml',
        out: 'rendered.mp4',
        proof: 'rendered.proof',
      });
      const mp4 = resolve(project, 'rendered.mp4');
      const proofDir = resolve(project, 'rendered.proof');
      const mp4Size = (await stat(mp4)).size;
      const verify = spawn(process.execPath, [
        resolve(repoRoot, 'dist/cli.js'),
        'proof',
        'verify',
        proofDir,
        '--json',
      ]);
      let verifyOut = '';
      verify.stdout.on('data', (c) => (verifyOut += String(c)));
      const verifyCode = await new Promise((r) => verify.on('close', r));
      results.check3 = {
        state: snapshot.state,
        completedActions: snapshot.completedActions,
        mp4Bytes: mp4Size,
        hasPreview: events.includes('capture.preview'),
        hasArtifact: events.includes('artifact.created'),
        hasProofCompleted: events.includes('proof.completed'),
        proofVerifyExit: verifyCode,
        proofLevel: (() => {
          try {
            return JSON.parse(verifyOut).proofLevel;
          } catch {
            return null;
          }
        })(),
        pass:
          snapshot.state === 'completed' &&
          mp4Size > 0 &&
          verifyCode === 0 &&
          events.includes('capture.preview'),
      };
    } finally {
      child.kill('SIGTERM');
      await delay(1500);
      child.kill('SIGKILL');
      await rm(project, { recursive: true, force: true });
    }
  }

  // ---- Check 4: missing target fails safely inside Electron ----
  {
    const project = await setupProject();
    const urlFile = resolve(project, 'studio-url.txt');
    const child = launchElectron(project, urlFile);
    try {
      const base = await waitForUrl(urlFile);
      const { snapshot } = await drive(base, {
        plan: 'missing-target.yaml',
        out: 'missing.mp4',
        proof: 'missing.proof',
      });
      const mp4Exists = await stat(resolve(project, 'missing.mp4')).then(
        () => true,
        () => false,
      );
      const proofManifestExists = await stat(resolve(project, 'missing.proof/manifest.json')).then(
        () => true,
        () => false,
      );
      results.check4 = {
        state: snapshot.state,
        errorCode: snapshot.error?.code ?? null,
        mp4Exists,
        proofManifestExists,
        pass:
          snapshot.state === 'failed' &&
          snapshot.error?.code === 'TARGET_NOT_FOUND' &&
          !mp4Exists &&
          !proofManifestExists,
      };
    } finally {
      child.kill('SIGTERM');
      await delay(1500);
      child.kill('SIGKILL');
      await rm(project, { recursive: true, force: true });
    }
  }

  // ---- Check 5: quit (SIGTERM) during an active run leaves no orphans ----
  {
    const project = await setupProject();
    const urlFile = resolve(project, 'studio-url.txt');
    const child = launchElectron(project, urlFile);
    let descriptorGone = false;
    try {
      const base = await waitForUrl(urlFile);
      const { call } = await session(base);
      await call('/api/plans/existing/approve', {
        method: 'POST',
        body: JSON.stringify({ path: 'demo.yaml' }),
      });
      const started = await (
        await call('/api/runs', {
          method: 'POST',
          body: JSON.stringify({
            approved: true,
            planPath: 'demo.yaml',
            outputPath: 'rendered.mp4',
            proofPath: 'rendered.proof',
          }),
        })
      ).json();
      const capturing = await waitUntilCapturing(base, started.runId);
      if (!capturing) throw new Error('run never reached capturing');
      // Snapshot the render's Chromium/FFmpeg PIDs while the run is live.
      await delay(500);
      const renderPidsBefore = await pids(RENDER_PROCESS_PATTERN);
      // Force-quit the shell via SIGTERM while Chromium/FFmpeg may be live.
      child.kill('SIGTERM');
      await new Promise((r) => child.on('close', r));
      await delay(2000);
      descriptorGone = await stat(resolve(project, '.soredemo/studio.json')).then(
        () => false,
        () => true,
      );
      const stillAlive = renderPidsBefore.filter((pid) => alive(pid));
      results.check5 = {
        capturingReached: capturing,
        descriptorRemoved: descriptorGone,
        renderPidsAtCapture: renderPidsBefore,
        renderPidsStillAliveAfterQuit: stillAlive,
        pass: capturing && descriptorGone && stillAlive.length === 0,
      };
    } finally {
      child.kill('SIGKILL');
      await rm(project, { recursive: true, force: true });
    }
  }
} finally {
  await fixture.close();
}

process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);
const allPass = Object.values(results).every((r) => r.pass);
process.exit(allPass ? 0 : 1);
