import { createHash } from 'node:crypto';
import { readdir, readFile, rm, stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { loadImage } from '@napi-rs/canvas';
import {
  DiagnosticFrameSink,
  writeCompositionManifest,
} from '../src/compositor/artifact-writer.js';
import { BaseFrameCompositor } from '../src/compositor/base-frame-compositor.js';
import { openCompositionPlan } from '../src/compositor/composition-plan-reader.js';
import { runComposition } from '../src/compositor/frame-runner.js';
import { SequentialSourceImageLoader } from '../src/compositor/source-image-loader.js';
import {
  type CompositionManifest,
  type FrameConsumer,
  OUTPUT_FPS,
  OUTPUT_HEIGHT,
  OUTPUT_WIDTH,
  type RawRgbaFrame,
} from '../src/compositor/types.js';
import { nearestOutputIndex } from '../src/resample/event-frame-mapping.js';
import type { ResampledFrameRecord } from '../src/resample/types.js';

interface TimelineClick {
  id: string;
  kind: 'click';
  mouseDownMs: number;
  target: { strategy: 'testId'; value: { testId: string } };
}

interface TimelineDocument {
  schemaVersion: 1;
  events: TimelineClick[];
}

class HashCollector implements FrameConsumer {
  readonly frameHashes = new Map<number, string>();
  private readonly rolling = createHash('sha256');

  async consume(frame: RawRgbaFrame): Promise<void> {
    this.frameHashes.set(frame.outputIndex, createHash('sha256').update(frame.data).digest('hex'));
    this.rolling.update(frame.data);
  }

  digest(): string {
    return this.rolling.digest('hex');
  }
}

function parseTimeline(value: unknown): TimelineDocument {
  if (typeof value !== 'object' || value === null) throw new Error('Timeline must be an object');
  const timeline = value as TimelineDocument;
  if (
    timeline.schemaVersion !== 1 ||
    !Array.isArray(timeline.events) ||
    timeline.events.length !== 30 ||
    timeline.events.some(
      (event) =>
        event.kind !== 'click' ||
        !Number.isFinite(event.mouseDownMs) ||
        event.target?.strategy !== 'testId' ||
        typeof event.target.value?.testId !== 'string',
    )
  ) {
    throw new Error('Day-3 timeline must contain 30 valid test-id click events');
  }
  return timeline;
}

async function artifactSize(directory: string): Promise<number> {
  let bytes = 0;
  for (const entry of await readdir(directory, { withFileTypes: true, recursive: true })) {
    if (entry.isFile()) bytes += (await stat(resolve(entry.parentPath, entry.name))).size;
  }
  return bytes;
}

function addPurpose(map: Map<number, string>, index: number, purpose: string): void {
  const existing = map.get(index);
  map.set(index, existing ? `${existing}; ${purpose}` : purpose);
}

async function selectedRecords(
  planDirectory: string,
  indices: ReadonlySet<number>,
): Promise<Map<number, ResampledFrameRecord>> {
  const reader = await openCompositionPlan(planDirectory);
  const records = new Map<number, ResampledFrameRecord>();
  for await (const record of reader.frames()) {
    if (indices.has(record.outputIndex)) records.set(record.outputIndex, record);
  }
  if (records.size !== indices.size)
    throw new Error('Not every selected output index exists in the plan');
  return records;
}

async function* subsetFrames(
  planDirectory: string,
  indices: ReadonlySet<number>,
): AsyncGenerator<ResampledFrameRecord> {
  const reader = await openCompositionPlan(planDirectory);
  for await (const record of reader.frames()) {
    if (indices.has(record.outputIndex)) yield record;
  }
}

async function runDeterministicSubset(
  planDirectory: string,
  captureDirectory: string,
  sourceWidth: number,
  sourceHeight: number,
  indices: ReadonlySet<number>,
): Promise<{ frameHashes: Map<number, string>; rollingDigest: string }> {
  const loader = await SequentialSourceImageLoader.create(
    captureDirectory,
    sourceWidth,
    sourceHeight,
  );
  const collector = new HashCollector();
  await runComposition({
    frames: subsetFrames(planDirectory, indices),
    sourceWidth,
    sourceHeight,
    loader,
    compositor: new BaseFrameCompositor(sourceWidth, sourceHeight),
    consumer: collector,
    requireConsecutiveOutputIndices: false,
  });
  return { frameHashes: collector.frameHashes, rollingDigest: collector.digest() };
}

function rssGrowth(samples: Array<{ frame: number; rssBytes: number }>): {
  firstQuarterAverageBytes: number;
  lastQuarterAverageBytes: number;
  slopeBytesPerFrame: number;
  clearLinearGrowth: boolean;
} {
  const quarter = Math.max(1, Math.floor(samples.length / 4));
  const average = (values: Array<{ rssBytes: number }>) =>
    values.reduce((total, value) => total + value.rssBytes, 0) / values.length;
  const firstQuarterAverageBytes = average(samples.slice(0, quarter));
  const lastQuarterAverageBytes = average(samples.slice(-quarter));
  const xMean = samples.reduce((total, sample) => total + sample.frame, 0) / samples.length;
  const yMean = samples.reduce((total, sample) => total + sample.rssBytes, 0) / samples.length;
  let numerator = 0;
  let denominator = 0;
  for (const sample of samples) {
    numerator += (sample.frame - xMean) * (sample.rssBytes - yMean);
    denominator += (sample.frame - xMean) ** 2;
  }
  const slopeBytesPerFrame = denominator === 0 ? 0 : numerator / denominator;
  const clearLinearGrowth =
    slopeBytesPerFrame > 128 * 1024 &&
    lastQuarterAverageBytes - firstQuarterAverageBytes > 256 * 1024 * 1024;
  return {
    firstQuarterAverageBytes,
    lastQuarterAverageBytes,
    slopeBytesPerFrame,
    clearLinearGrowth,
  };
}

const planDirectory = resolve(process.argv[2] ?? '.tmp/day4-resampler-spike');
const outputDirectory = resolve(process.argv[3] ?? '.tmp/day5-compositor-spike');
const temporaryRoot = resolve('.tmp');
if (!outputDirectory.startsWith(`${temporaryRoot}/`)) {
  throw new Error('Day-5 spike output must remain under the repository .tmp directory');
}
await rm(outputDirectory, { recursive: true, force: true });

const initialPlan = await openCompositionPlan(planDirectory);
const { manifest: planManifest } = initialPlan;
const captureDirectory = resolve(planManifest.sourceCapturePath);
const timeline = parseTimeline(
  JSON.parse(await readFile(resolve(captureDirectory, 'timeline.json'), 'utf8')),
);
const clickIndices = new Map<TimelineClick, number>();
for (const click of timeline.events) {
  clickIndices.set(
    click,
    nearestOutputIndex(click.mouseDownMs, planManifest.outputFrameCount, OUTPUT_FPS),
  );
}
const clickRecords = await selectedRecords(planDirectory, new Set(clickIndices.values()));
let largestErrorClick = timeline.events[0];
let largestError = Number.NEGATIVE_INFINITY;
for (const click of timeline.events) {
  const index = clickIndices.get(click);
  const selected = index === undefined ? undefined : clickRecords.get(index);
  if (!selected) throw new Error(`Missing resample record for ${click.id}`);
  const error = Math.abs(selected.sourceTimestampMs - click.mouseDownMs);
  if (error > largestError) {
    largestError = error;
    largestErrorClick = click;
  }
}
if (!largestErrorClick) throw new Error('Timeline did not contain a click');
const staticClick = timeline.events.find((click) => click.target.value.testId === 'static-target');
const hoverClick = timeline.events.find((click) => click.target.value.testId === 'hover-target');
if (!staticClick || !hoverClick)
  throw new Error('Timeline is missing static or hover click targets');

const snapshotPurposes = new Map<number, string>();
addPurpose(snapshotPurposes, 0, 'first frame');
addPurpose(snapshotPurposes, Math.floor(planManifest.outputFrameCount / 2), 'middle frame');
addPurpose(snapshotPurposes, planManifest.outputFrameCount - 1, 'final frame');
addPurpose(snapshotPurposes, clickIndices.get(staticClick) ?? -1, 'static-target click frame');
addPurpose(snapshotPurposes, clickIndices.get(hoverClick) ?? -1, 'hover-target click frame');
addPurpose(
  snapshotPurposes,
  clickIndices.get(largestErrorClick) ?? -1,
  `largest source-to-mouse-down error (${largestErrorClick.id})`,
);
if (snapshotPurposes.has(-1)) throw new Error('Unable to map one or more snapshot clicks');

const compositor = new BaseFrameCompositor(
  planManifest.sourcePixelWidth,
  planManifest.sourcePixelHeight,
);
const sink = await DiagnosticFrameSink.create(outputDirectory, compositor, snapshotPurposes);
const loader = await SequentialSourceImageLoader.create(
  captureDirectory,
  planManifest.sourcePixelWidth,
  planManifest.sourcePixelHeight,
);
const rssBeforeBytes = process.memoryUsage().rss;
const rssSamples = [{ frame: 0, rssBytes: rssBeforeBytes }];
const startedAt = performance.now();
const { run, sinkResult } = await (async () => {
  try {
    const plan = await openCompositionPlan(planDirectory);
    const run = await runComposition({
      frames: plan.frames(),
      sourceWidth: planManifest.sourcePixelWidth,
      sourceHeight: planManifest.sourcePixelHeight,
      loader,
      compositor,
      consumer: sink,
      onFrameComplete: (index) => {
        if ((index + 1) % 25 === 0) {
          rssSamples.push({ frame: index + 1, rssBytes: process.memoryUsage().rss });
        }
      },
    });
    return { run, sinkResult: await sink.finish() };
  } catch (error) {
    await sink.abort();
    throw error;
  }
})();
const executionMs = performance.now() - startedAt;
const rssAfterBytes = process.memoryUsage().rss;
rssSamples.push({ frame: run.framesProcessed, rssBytes: rssAfterBytes });
const peakRssBytes = Math.max(...rssSamples.map((sample) => sample.rssBytes));
const growth = rssGrowth(rssSamples);

const subsetIndices = new Set<number>();
for (let index = 0; index < Math.min(10, planManifest.outputFrameCount); index += 1) {
  subsetIndices.add(index);
}
subsetIndices.add(clickIndices.get(staticClick) ?? -1);
subsetIndices.add(clickIndices.get(hoverClick) ?? -1);
for (
  let index = Math.max(0, planManifest.outputFrameCount - 10);
  index < planManifest.outputFrameCount;
  index += 1
) {
  subsetIndices.add(index);
}
subsetIndices.delete(-1);
const firstReplay = await runDeterministicSubset(
  planDirectory,
  captureDirectory,
  planManifest.sourcePixelWidth,
  planManifest.sourcePixelHeight,
  subsetIndices,
);
const secondReplay = await runDeterministicSubset(
  planDirectory,
  captureDirectory,
  planManifest.sourcePixelWidth,
  planManifest.sourcePixelHeight,
  subsetIndices,
);
const deterministic =
  firstReplay.rollingDigest === secondReplay.rollingDigest &&
  [...firstReplay.frameHashes].every(
    ([index, hash]) => secondReplay.frameHashes.get(index) === hash,
  );

const canvasPackage = JSON.parse(
  await readFile(resolve('node_modules/@napi-rs/canvas/package.json'), 'utf8'),
) as { version: string };
const manifest: CompositionManifest = {
  schemaVersion: 1,
  sourceCapturePath: captureDirectory,
  sourceResamplePlanPath: planDirectory,
  sourcePixelWidth: planManifest.sourcePixelWidth,
  sourcePixelHeight: planManifest.sourcePixelHeight,
  outputWidth: OUTPUT_WIDTH,
  outputHeight: OUTPUT_HEIGHT,
  outputFps: OUTPUT_FPS,
  outputFrameCount: run.framesProcessed,
  pixelFormat: 'rgba',
  channelOrder: 'rgba',
  alphaMode: 'opaque',
  fitMode: 'contain',
  contentRect: compositor.contentRect,
  matte: { red: 0, green: 0, blue: 0, alpha: 255 },
  canvasPackage: { name: '@napi-rs/canvas', version: canvasPackage.version },
  decoding: {
    decodeCount: run.sourceImages.decodeCount,
    cacheHits: run.sourceImages.cacheHits,
    cacheMisses: run.sourceImages.cacheMisses,
    maxDecodedImagesRetained: run.sourceImages.maxDecodedImagesRetained,
  },
  bytesProcessed: run.bytesProcessed,
  rollingRgbaSha256: sinkResult.rollingRgbaSha256,
  snapshots: sinkResult.snapshots,
  performance: {
    executionMs,
    framesPerSecond: run.framesProcessed / (executionMs / 1000),
    rssBeforeBytes,
    rssAfterBytes,
    peakRssBytes,
  },
};
await writeCompositionManifest(outputDirectory, manifest);

const snapshotDimensions = await Promise.all(
  sinkResult.snapshots.map(async (snapshot) => {
    const image = await loadImage(resolve(outputDirectory, snapshot.file));
    return { file: snapshot.file, width: image.width, height: image.height };
  }),
);
const frameHashLines = (await readFile(resolve(outputDirectory, 'frame-hashes.jsonl'), 'utf8'))
  .trim()
  .split('\n').length;
const outputArtifactSizeBytes = await artifactSize(outputDirectory);
const passed =
  run.framesProcessed === planManifest.outputFrameCount &&
  sinkResult.frameCount === planManifest.outputFrameCount &&
  frameHashLines === planManifest.outputFrameCount &&
  run.maxActiveFrames <= 1 &&
  run.sourceImages.maxDecodedImagesRetained <= 1 &&
  run.sourceImages.outOfOrderSourceSelections === 0 &&
  peakRssBytes < 1024 ** 3 &&
  !growth.clearLinearGrowth &&
  deterministic &&
  snapshotDimensions.every(
    (snapshot) => snapshot.width === OUTPUT_WIDTH && snapshot.height === OUTPUT_HEIGHT,
  );

const summary = {
  passed,
  planDirectory,
  captureDirectory,
  outputDirectory,
  outputFrameCount: run.framesProcessed,
  sourceImages: run.sourceImages,
  bytesProcessed: run.bytesProcessed,
  rollingRgbaSha256: sinkResult.rollingRgbaSha256,
  contentRect: compositor.contentRect,
  executionMs,
  framesPerSecond: manifest.performance.framesPerSecond,
  memory: { rssBeforeBytes, peakRssBytes, rssAfterBytes, ...growth },
  artifact: {
    frameHashLines,
    outputArtifactSizeBytes,
    snapshots: sinkResult.snapshots,
    snapshotDimensions,
  },
  deterministicSubset: {
    frameCount: subsetIndices.size,
    indices: [...subsetIndices].sort((left, right) => left - right),
    firstDigest: firstReplay.rollingDigest,
    secondDigest: secondReplay.rollingDigest,
    identical: deterministic,
  },
};
process.stderr.write(
  [
    'Day 5 minimal compositor',
    `frames       ${run.framesProcessed} at ${manifest.performance.framesPerSecond.toFixed(2)} fps`,
    `decoding     ${run.sourceImages.decodeCount} misses / ${run.sourceImages.cacheHits} hits`,
    `memory       ${(rssBeforeBytes / 1024 ** 2).toFixed(1)} MiB before / ${(peakRssBytes / 1024 ** 2).toFixed(1)} MiB peak / ${(rssAfterBytes / 1024 ** 2).toFixed(1)} MiB after`,
    `snapshots    ${sinkResult.snapshots.length}`,
    `determinism  ${deterministic ? 'identical' : 'mismatch'}`,
    `result       ${passed ? 'PASS' : 'FAIL'}`,
    '',
  ].join('\n'),
);
process.stdout.write(`${JSON.stringify(summary)}\n`);
if (!passed) process.exitCode = 1;
