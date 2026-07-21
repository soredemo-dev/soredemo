import { createHash } from 'node:crypto';
import { readdir, readFile, rm, stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { loadImage } from '@napi-rs/canvas';
import { openCompositionPlan } from '../src/compositor/composition-plan-reader.js';
import {
  type CursorCompositionManifest,
  CursorDiagnosticSink,
  writeCursorCompositionArtifacts,
} from '../src/compositor/cursor-artifact-writer.js';
import { loadCursorAsset } from '../src/compositor/cursor-asset.js';
import { cssPointToScreen } from '../src/compositor/cursor-coordinate-transform.js';
import {
  CursorFrameCompositor,
  type CursorRawRgbaFrame,
  cursorHotspot,
} from '../src/compositor/cursor-frame-compositor.js';
import { SequentialCursorEvaluator } from '../src/compositor/cursor-track.js';
import { runComposition } from '../src/compositor/frame-runner.js';
import {
  type CursorLandingMeasurement,
  cursorLandingGatePasses,
  cursorLandingStatistics,
  measureCursorLanding,
} from '../src/compositor/landing-statistics.js';
import { SequentialSourceImageLoader } from '../src/compositor/source-image-loader.js';
import {
  type FrameConsumer,
  OUTPUT_FPS,
  OUTPUT_HEIGHT,
  OUTPUT_WIDTH,
  type RawRgbaFrame,
} from '../src/compositor/types.js';
import { nearestOutputIndex } from '../src/resample/event-frame-mapping.js';
import type { ResampledFrameRecord } from '../src/resample/types.js';
import { buildCursorTrack } from '../src/timeline/cursor-track-validation.js';
import type { ClickTimelineEvent, TimelineDocument } from '../src/timeline/types.js';
import { validateTimelineDocument } from '../src/timeline/validation.js';

class ReplayCollector implements FrameConsumer {
  readonly hashes = new Map<number, string>();
  readonly pngHashes = new Map<number, string>();
  readonly cursorStates = new Map<number, string>();
  readonly measurements: CursorLandingMeasurement[] = [];
  private readonly rolling = createHash('sha256');

  constructor(
    private readonly compositor: CursorFrameCompositor,
    private readonly viewport: { width: number; height: number },
    private readonly landingEvents: ReadonlyMap<number, readonly ClickTimelineEvent[]>,
  ) {}

  async consume(rawFrame: RawRgbaFrame): Promise<void> {
    const frame = rawFrame as CursorRawRgbaFrame;
    this.hashes.set(frame.outputIndex, createHash('sha256').update(frame.data).digest('hex'));
    this.pngHashes.set(
      frame.outputIndex,
      createHash('sha256').update(this.compositor.base.png()).digest('hex'),
    );
    this.cursorStates.set(frame.outputIndex, JSON.stringify(frame.cursor));
    this.rolling.update(frame.data);
    for (const click of this.landingEvents.get(frame.outputIndex) ?? []) {
      const clickScreen = cssPointToScreen(
        click.clickPoint,
        this.viewport,
        this.compositor.base.contentRect,
      );
      this.measurements.push(
        measureCursorLanding({
          click,
          outputFrame: frameRecord(frame),
          cursor: frame.cursor,
          cursorScreen: cursorHotspot(frame),
          clickScreen,
        }),
      );
    }
  }

  digest(): string {
    return this.rolling.digest('hex');
  }
}

function frameRecord(frame: RawRgbaFrame): ResampledFrameRecord {
  const signedSourceDeltaMs = frame.sourceTimestampMs - frame.outputTimestampMs;
  return {
    outputIndex: frame.outputIndex,
    outputTimestampMs: frame.outputTimestampMs,
    sourceIndex: frame.sourceIndex,
    sourceFile: '',
    sourceTimestampMs: frame.sourceTimestampMs,
    signedSourceDeltaMs,
    absoluteSourceDeltaMs: Math.abs(signedSourceDeltaMs),
    relation: signedSourceDeltaMs < 0 ? 'before' : signedSourceDeltaMs > 0 ? 'after' : 'exact',
  };
}

function parseTimeline(value: unknown, durationMs: number): TimelineDocument {
  if (typeof value !== 'object' || value === null) throw new Error('Timeline must be an object');
  const timeline = value as TimelineDocument;
  validateTimelineDocument(timeline, durationMs);
  if (timeline.events.length !== 30) throw new Error('Day-6 gate requires exactly 30 click events');
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
  if (records.size !== indices.size) throw new Error('Not every selected output frame exists');
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

function rssDiagnostics(samples: Array<{ frame: number; rssBytes: number }>) {
  const xMean = samples.reduce((total, sample) => total + sample.frame, 0) / samples.length;
  const yMean = samples.reduce((total, sample) => total + sample.rssBytes, 0) / samples.length;
  let numerator = 0;
  let denominator = 0;
  for (const sample of samples) {
    numerator += (sample.frame - xMean) * (sample.rssBytes - yMean);
    denominator += (sample.frame - xMean) ** 2;
  }
  return {
    peakRssBytes: Math.max(...samples.map((sample) => sample.rssBytes)),
    slopeBytesPerFrame: denominator === 0 ? 0 : numerator / denominator,
  };
}

async function runReplay(options: {
  planDirectory: string;
  captureDirectory: string;
  cursorFile: string;
  timeline: TimelineDocument;
  viewport: { width: number; height: number };
  sourceWidth: number;
  sourceHeight: number;
  indices: ReadonlySet<number>;
  landingEvents: ReadonlyMap<number, readonly ClickTimelineEvent[]>;
}) {
  const asset = await loadCursorAsset(options.cursorFile);
  const track = buildCursorTrack(options.timeline.events, options.viewport);
  const compositor = new CursorFrameCompositor(
    options.sourceWidth,
    options.sourceHeight,
    options.viewport,
    asset,
    new SequentialCursorEvaluator(track),
    new Set(options.landingEvents.keys()),
  );
  const collector = new ReplayCollector(compositor, options.viewport, options.landingEvents);
  await runComposition({
    frames: subsetFrames(options.planDirectory, options.indices),
    sourceWidth: options.sourceWidth,
    sourceHeight: options.sourceHeight,
    loader: await SequentialSourceImageLoader.create(
      options.captureDirectory,
      options.sourceWidth,
      options.sourceHeight,
    ),
    compositor,
    consumer: collector,
    requireConsecutiveOutputIndices: false,
  });
  return {
    hashes: [...collector.hashes],
    pngHashes: [...collector.pngHashes],
    cursorStates: [...collector.cursorStates],
    measurements: collector.measurements,
    digest: collector.digest(),
  };
}

const planDirectory = resolve(process.argv[2] ?? '.tmp/day4-resampler-spike');
const outputDirectory = resolve(process.argv[3] ?? '.tmp/day6-cursor-landing-gate');
const cursorFile = resolve('assets/cursor.svg');
const temporaryRoot = resolve('.tmp');
if (!outputDirectory.startsWith(`${temporaryRoot}/`)) {
  throw new Error('Day-6 gate output must remain under the repository .tmp directory');
}
await rm(outputDirectory, { recursive: true, force: true });

const initialPlan = await openCompositionPlan(planDirectory);
const planManifest = initialPlan.manifest;
const captureDirectory = resolve(planManifest.sourceCapturePath);
const captureManifest = JSON.parse(
  await readFile(resolve(captureDirectory, 'manifest.json'), 'utf8'),
) as { captureDurationMs: number; viewport: { width: number; height: number } };
if (captureManifest.viewport.width !== 1440 || captureManifest.viewport.height !== 900) {
  throw new Error('Day-6 gate requires the 1440x900 CSS viewport');
}
const timelinePath = resolve(captureDirectory, 'timeline.json');
const timeline = parseTimeline(
  JSON.parse(await readFile(timelinePath, 'utf8')),
  captureManifest.captureDurationMs,
);
const track = buildCursorTrack(timeline.events, captureManifest.viewport);
const asset = await loadCursorAsset(cursorFile);

const landingEvents = new Map<number, ClickTimelineEvent[]>();
const clickOutputIndices = new Map<string, number>();
for (const click of timeline.events) {
  const index = nearestOutputIndex(click.mouseDownMs, planManifest.outputFrameCount, OUTPUT_FPS);
  clickOutputIndices.set(click.id, index);
  const events = landingEvents.get(index) ?? [];
  events.push(click);
  landingEvents.set(index, events);
}
const clickFrames = await selectedRecords(planDirectory, new Set(clickOutputIndices.values()));
const previewEvaluator = new SequentialCursorEvaluator(track);
const previewMeasurements: CursorLandingMeasurement[] = [];
for (const click of timeline.events) {
  const index = clickOutputIndices.get(click.id);
  const record = index === undefined ? undefined : clickFrames.get(index);
  if (!record) throw new Error(`Missing mapped output frame for ${click.id}`);
  const cursor = previewEvaluator.evaluate(record.outputTimestampMs);
  if (!cursor.visible || cursor.cssX === undefined || cursor.cssY === undefined) {
    throw new Error(`${click.id} has no cursor in landing preview`);
  }
  const cursorScreen = cssPointToScreen(
    { x: cursor.cssX, y: cursor.cssY },
    captureManifest.viewport,
    { x: 96, y: 0, width: 1728, height: 1080 },
  );
  previewMeasurements.push(
    measureCursorLanding({
      click,
      outputFrame: record,
      cursor,
      cursorScreen,
      clickScreen: cssPointToScreen(click.clickPoint, captureManifest.viewport, {
        x: 96,
        y: 0,
        width: 1728,
        height: 1080,
      }),
    }),
  );
}
const previewStatistics = cursorLandingStatistics(previewMeasurements);
const predictedWorst = timeline.events.find((click) => click.id === previewStatistics.worstClickId);
const staticClick = timeline.events.find((click) => click.target.value.testId === 'static-target');
const hoverClick = timeline.events.find((click) => click.target.value.testId === 'hover-target');
if (!predictedWorst || !staticClick || !hoverClick)
  throw new Error('Snapshot click selection failed');

const firstVisibleIndex = Math.ceil((track.firstPointMs * OUTPUT_FPS) / 1000);
const fullSnapshots = new Map<number, string>();
addPurpose(fullSnapshots, firstVisibleIndex, 'first visible cursor frame');
addPurpose(fullSnapshots, clickOutputIndices.get(staticClick.id) ?? -1, 'first static click');
addPurpose(fullSnapshots, clickOutputIndices.get(hoverClick.id) ?? -1, 'first hover click');
addPurpose(
  fullSnapshots,
  clickOutputIndices.get(predictedWorst.id) ?? -1,
  'worst landing-error click',
);
addPurpose(fullSnapshots, planManifest.outputFrameCount - 1, 'final frame');
if (fullSnapshots.has(-1)) throw new Error('A full-frame snapshot could not be mapped');

const compositor = new CursorFrameCompositor(
  planManifest.sourcePixelWidth,
  planManifest.sourcePixelHeight,
  captureManifest.viewport,
  asset,
  new SequentialCursorEvaluator(track),
  new Set(landingEvents.keys()),
);
const sink = await CursorDiagnosticSink.create({
  outputDirectory,
  compositor: compositor.base,
  viewport: captureManifest.viewport,
  landingEvents,
  fullSnapshots,
});
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
const memory = rssDiagnostics(rssSamples);
const landing = cursorLandingStatistics(sinkResult.measurements);
const staticLanding = cursorLandingStatistics(
  sinkResult.measurements.filter((item) => item.targetTestId === 'static-target'),
);
const hoverLanding = cursorLandingStatistics(
  sinkResult.measurements.filter((item) => item.targetTestId === 'hover-target'),
);
if (landing.worstClickId !== predictedWorst.id) {
  throw new Error('Actual worst landing click differs from the snapshot preview');
}

const subsetIndices = new Set<number>([
  0,
  firstVisibleIndex,
  Math.min(firstVisibleIndex + 1, planManifest.outputFrameCount - 1),
  clickOutputIndices.get(staticClick.id) ?? -1,
  clickOutputIndices.get(hoverClick.id) ?? -1,
  clickOutputIndices.get(predictedWorst.id) ?? -1,
  Math.max(0, planManifest.outputFrameCount - 2),
  planManifest.outputFrameCount - 1,
]);
subsetIndices.delete(-1);
const replayLandingEvents = new Map<number, readonly ClickTimelineEvent[]>();
for (const [index, events] of landingEvents) {
  if (subsetIndices.has(index)) replayLandingEvents.set(index, events);
}
const replayOptions = {
  planDirectory,
  captureDirectory,
  cursorFile,
  timeline,
  viewport: captureManifest.viewport,
  sourceWidth: planManifest.sourcePixelWidth,
  sourceHeight: planManifest.sourcePixelHeight,
  indices: subsetIndices,
  landingEvents: replayLandingEvents,
};
const firstReplay = await runReplay(replayOptions);
const secondReplay = await runReplay(replayOptions);
const deterministicReplay = JSON.stringify(firstReplay) === JSON.stringify(secondReplay);

const manifest: CursorCompositionManifest = {
  schemaVersion: 1,
  sourceCapturePath: captureDirectory,
  sourceResamplePlanPath: planDirectory,
  sourceTimelinePath: timelinePath,
  outputWidth: OUTPUT_WIDTH,
  outputHeight: OUTPUT_HEIGHT,
  outputFps: OUTPUT_FPS,
  outputFrameCount: run.framesProcessed,
  cssViewport: { width: 1440, height: 900 },
  contentRect: compositor.base.contentRect,
  cursor: {
    assetFile: 'assets/cursor.svg',
    assetSha256: asset.sha256,
    ...asset.definition,
    coordinateSpace: 'output-screen',
  },
  cursorTrack: {
    clickEvents: timeline.events.length,
    pathPoints: track.pointCount,
    firstPointMs: track.firstPointMs,
    lastPointMs: track.lastPointMs,
  },
  cursorFrames: sinkResult.cursorFrames,
  landing,
  decoding: {
    decodeCount: run.sourceImages.decodeCount,
    cacheHits: run.sourceImages.cacheHits,
    cacheMisses: run.sourceImages.cacheMisses,
    maxDecodedImagesRetained: run.sourceImages.maxDecodedImagesRetained,
  },
  bytesProcessed: run.bytesProcessed,
  rollingRgbaSha256: sinkResult.rollingRgbaSha256,
  performance: {
    executionMs,
    framesPerSecond: run.framesProcessed / (executionMs / 1000),
    rssBeforeBytes,
    rssAfterBytes,
    peakRssBytes: memory.peakRssBytes,
    rssSlopeBytesPerFrame: memory.slopeBytesPerFrame,
  },
  snapshots: sinkResult.snapshots,
};
await writeCursorCompositionArtifacts({
  outputDirectory,
  manifest,
  measurements: sinkResult.measurements,
});

const snapshotDimensions = await Promise.all(
  sinkResult.snapshots.map(async (snapshot) => {
    const image = await loadImage(resolve(outputDirectory, snapshot.file));
    return { file: snapshot.file, width: image.width, height: image.height };
  }),
);
const hashLines = (await readFile(resolve(outputDirectory, 'frame-hashes.jsonl'), 'utf8'))
  .trim()
  .split('\n').length;
const artifactSizeBytes = await artifactSize(outputDirectory);
const passed =
  run.framesProcessed === planManifest.outputFrameCount &&
  sinkResult.frameCount === planManifest.outputFrameCount &&
  hashLines === planManifest.outputFrameCount &&
  sinkResult.measurements.length === 30 &&
  cursorLandingGatePasses(landing) &&
  run.maxActiveFrames <= 1 &&
  run.sourceImages.maxDecodedImagesRetained <= 1 &&
  memory.peakRssBytes < 1024 ** 3 &&
  memory.slopeBytesPerFrame < 128 * 1024 &&
  deterministicReplay &&
  snapshotDimensions
    .filter((snapshot) => snapshot.file.includes('/click-'))
    .every((snapshot) => snapshot.width === 256 && snapshot.height === 256);

const summary = {
  passed,
  outputFrameCount: run.framesProcessed,
  cursorTrack: manifest.cursorTrack,
  cursorFrames: sinkResult.cursorFrames,
  cursor: manifest.cursor,
  landing,
  staticLanding,
  hoverLanding,
  measurements: sinkResult.measurements,
  clickFeedback: 'deferred',
  bytesProcessed: run.bytesProcessed,
  rollingRgbaSha256: sinkResult.rollingRgbaSha256,
  decoding: run.sourceImages,
  performance: manifest.performance,
  deterministicSubset: {
    indices: [...subsetIndices].sort((left, right) => left - right),
    frameCount: subsetIndices.size,
    firstDigest: firstReplay.digest,
    secondDigest: secondReplay.digest,
    identical: deterministicReplay,
  },
  artifact: {
    hashLines,
    artifactSizeBytes,
    snapshots: sinkResult.snapshots.length,
    landingCrops: snapshotDimensions.filter((snapshot) => snapshot.file.includes('/click-')).length,
    fullFrames: snapshotDimensions.filter((snapshot) => snapshot.file.includes('/frame-')).length,
    dimensions: snapshotDimensions,
  },
};
process.stderr.write(
  [
    'Day 6 cursor landing gate',
    `frames       ${run.framesProcessed} at ${manifest.performance.framesPerSecond.toFixed(2)} fps`,
    `cursor       ${sinkResult.cursorFrames.visible} visible / ${track.pointCount} recorded points`,
    `landing      median ${landing.distanceOutputPx.median.toFixed(3)} px / p95 ${landing.distanceOutputPx.p95.toFixed(3)} px / max ${landing.distanceOutputPx.max.toFixed(3)} px`,
    `memory       ${(rssBeforeBytes / 1024 ** 2).toFixed(1)} MiB before / ${(memory.peakRssBytes / 1024 ** 2).toFixed(1)} MiB peak / ${(rssAfterBytes / 1024 ** 2).toFixed(1)} MiB after`,
    `replay       ${deterministicReplay ? 'identical' : 'mismatch'}`,
    `result       ${passed ? 'PASS' : 'FAIL'}`,
    '',
  ].join('\n'),
);
process.stdout.write(`${JSON.stringify(summary)}\n`);
if (!passed) process.exitCode = 1;
