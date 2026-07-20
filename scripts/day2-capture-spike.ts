import { createHash } from 'node:crypto';
import { mkdir, readdir, readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { captureSession, summarizeCapture } from '../src/capture/capture-session.js';
import { startFixtureServer } from '../test/fixtures/web-app/server.js';

const fixtureDirectory = resolve('test/fixtures/web-app');
const outputRoot = resolve(
  '.tmp/day2-capture-spike',
  new Date().toISOString().replaceAll(':', '-').replaceAll('.', '-'),
);
const durationMs = 6_000;
const runCount = 3;

async function fixtureHash(): Promise<string> {
  const hash = createHash('sha256');
  for (const file of ['index.html', 'styles.css', 'app.js']) {
    hash.update(await readFile(resolve(fixtureDirectory, file)));
  }
  return hash.digest('hex');
}

async function verifyBundle(outputDirectory: string, expectedFrameCount: number): Promise<void> {
  const manifest = JSON.parse(
    await readFile(resolve(outputDirectory, 'manifest.json'), 'utf8'),
  ) as { frameCount: number };
  const lines = (await readFile(resolve(outputDirectory, 'frames.jsonl'), 'utf8'))
    .trim()
    .split('\n');
  const records = lines.map(
    (line) =>
      JSON.parse(line) as { index: number; file: string; pixelWidth: number; pixelHeight: number },
  );
  const files = (await readdir(resolve(outputDirectory, 'frames')))
    .filter((file) => file.endsWith('.jpg'))
    .sort();
  const recordFiles = records.map((record) => record.file.replace('frames/', ''));
  if (
    manifest.frameCount !== expectedFrameCount ||
    lines.length !== expectedFrameCount ||
    files.length !== expectedFrameCount ||
    files.some((file, index) => file !== recordFiles[index]) ||
    records.some(
      (record, index) =>
        record.index !== index + 1 || record.pixelWidth !== 2880 || record.pixelHeight !== 1800,
    )
  ) {
    throw new Error('Capture bundle manifest, records, and JPEG files do not match');
  }
}

await mkdir(outputRoot, { recursive: true });
const server = await startFixtureServer(0, fixtureDirectory);
try {
  const scriptHash = await fixtureHash();
  for (let run = 1; run <= runCount; run += 1) {
    const outputDirectory = resolve(outputRoot, `run-${run}`);
    const result = await captureSession({
      url: `${server.url}/workspace`,
      outputDirectory,
      durationMs,
      sourceIdentifier: 'test/fixtures/web-app#animated-capture-probe',
      scriptHash,
    });
    await verifyBundle(outputDirectory, result.manifest.frameCount);
    process.stdout.write(`${JSON.stringify(summarizeCapture(run, result))}\n`);
  }
} finally {
  await server.close();
}
