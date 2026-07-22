import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFile, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { startFixtureServer } from '../test/fixtures/web-app/server.js';
import { verifyLiveWorkspace } from '../test/golden-tools/live-visual.js';
import { stableJson } from '../test/golden-tools/profile.js';

const outputRoot = resolve('.tmp/day14-launch');
const outputFile = resolve(outputRoot, 'soredemo-alpha-demo.mp4');
const posterFile = resolve(outputRoot, 'poster.png');
const planFile = resolve('examples/launch-showcase/demo.yaml');

await rm(outputRoot, { recursive: true, force: true });
await mkdir(outputRoot, { recursive: true });
const server = await startFixtureServer(4184, resolve('examples/launch-showcase'));

try {
  const rendered = await run(process.execPath, [
    resolve('dist/cli.js'),
    'render',
    planFile,
    '--out',
    outputFile,
    '--keep-artifacts',
    '--json',
  ]);
  if (rendered.code !== 0) {
    throw new Error(
      `Launch render failed (${rendered.code}): ${rendered.stderr}\n${rendered.stdout}`,
    );
  }
  const renderResult = JSON.parse(rendered.stdout) as LaunchRenderResult;
  if (!renderResult.success || !renderResult.artifactsPath) {
    throw new Error('Launch render did not return a successful preserved workspace');
  }
  const liveVerification = await verifyLiveWorkspace(renderResult.artifactsPath, outputFile);
  const workspace = resolve(renderResult.artifactsPath);
  const landing = JSON.parse(
    await readFile(resolve(workspace, 'composition/cursor-action-landings.json'), 'utf8'),
  ) as { measurements: Array<{ kind: string; outputIndex: number }> };
  const posterMeasurement = landing.measurements.filter((value) => value.kind === 'click').at(-1);
  if (!posterMeasurement) throw new Error('Launch render has no click landing for its poster');

  const ffprobeSource = resolve(workspace, 'encode/ffprobe.json');
  const ffprobeFile = resolve(outputRoot, 'ffprobe.json');
  await copyFile(ffprobeSource, ffprobeFile);
  await extractPoster(outputFile, posterFile, posterMeasurement.outputIndex);

  const launchInputs = await hashFiles([
    'examples/launch-showcase/index.html',
    'examples/launch-showcase/styles.css',
    'examples/launch-showcase/app.js',
    'examples/launch-showcase/demo.yaml',
    'examples/launch-showcase/soredemo.config.yaml',
  ]);
  const safeRenderResult = {
    success: renderResult.success,
    outputPath: '.tmp/day14-launch/soredemo-alpha-demo.mp4',
    outputBytes: renderResult.outputBytes,
    outputSha256: renderResult.outputSha256,
    durationSeconds: renderResult.durationSeconds,
    frameCount: renderResult.frameCount,
    fps: renderResult.fps,
    actionCount: renderResult.actionCount,
    captureFrameCount: renderResult.captureFrameCount,
    cursorActionMeasurements: renderResult.cursorActionMeasurements,
    renderDurationMs: renderResult.renderDurationMs,
    diagnostics: renderResult.diagnostics,
    warnings: renderResult.warnings.filter((warning) => warning.code !== 'WORKSPACE_PRESERVED'),
  };
  const safeStructuralAuthority = {
    ...liveVerification,
    output: { ...liveVerification.output, file: '.tmp/day14-launch/soredemo-alpha-demo.mp4' },
    workspace: '<local-preserved-workspace>',
  };
  const manifestFile = resolve(outputRoot, 'launch-demo-manifest.json');
  const manifest = {
    schemaVersion: 1,
    publicSafeSyntheticContent: true,
    productionCommand:
      'soredemo render examples/launch-showcase/demo.yaml --out .tmp/day14-launch/soredemo-alpha-demo.mp4 --keep-artifacts --json',
    sourceFiles: launchInputs,
    render: safeRenderResult,
    structuralAuthority: safeStructuralAuthority,
    poster: {
      outputIndex: posterMeasurement.outputIndex,
      file: 'poster.png',
      width: 1920,
      height: 1080,
      sha256: await sha256(posterFile),
    },
  };
  await writeFile(manifestFile, stableJson(manifest));

  const assets = await Promise.all(
    [outputFile, posterFile, manifestFile, ffprobeFile].map(async (file) => ({
      file: file.slice(outputRoot.length + 1),
      byteLength: (await stat(file)).size,
      sha256: await sha256(file),
    })),
  );
  await Promise.all([
    writeFile(resolve(outputRoot, 'release-assets.json'), stableJson({ schemaVersion: 1, assets })),
    writeFile(
      resolve(outputRoot, 'SHA256SUMS'),
      `${assets.map((asset) => `${asset.sha256}  ${asset.file}`).join('\n')}\n`,
    ),
  ]);
  process.stdout.write(stableJson({ passed: true, manifest, assets }));
} finally {
  await server.close();
}

async function extractPoster(video: string, output: string, frameIndex: number): Promise<void> {
  const result = await run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-i',
    video,
    '-vf',
    `select=eq(n\\,${frameIndex})`,
    '-frames:v',
    '1',
    '-y',
    output,
  ]);
  if (result.code !== 0) throw new Error(`Poster extraction failed: ${result.stderr}`);
}

async function hashFiles(
  files: readonly string[],
): Promise<Array<{ file: string; sha256: string }>> {
  return Promise.all(files.map(async (file) => ({ file, sha256: await sha256(resolve(file)) })));
}

async function sha256(file: string): Promise<string> {
  return createHash('sha256')
    .update(await readFile(file))
    .digest('hex');
}

async function run(file: string, args: readonly string[]): Promise<CommandResult> {
  const child = spawn(file, [...args], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk: string) => {
    stdout += chunk;
    if (stdout.length > 4 * 1024 * 1024) throw new Error(`${file} stdout exceeded its bound`);
  });
  child.stderr.on('data', (chunk: string) => {
    stderr = `${stderr}${chunk}`.slice(-4 * 1024 * 1024);
  });
  const code = await new Promise<number | null>((accept, reject) => {
    child.once('error', reject);
    child.once('close', accept);
  });
  return { code, stdout, stderr };
}

interface CommandResult {
  code: number | null;
  stdout: string;
  stderr: string;
}

interface LaunchRenderResult {
  success: boolean;
  outputPath: string;
  outputBytes: number;
  outputSha256: string;
  durationSeconds: number;
  frameCount: number;
  fps: number;
  actionCount: number;
  captureFrameCount: number;
  cursorActionMeasurements: { moveTo: number; click: number; type: number };
  renderDurationMs: number;
  artifactsPath?: string;
  warnings: Array<{ code: string; message: string }>;
  diagnostics: {
    encoder: { maxPendingFrames: number };
  };
}
