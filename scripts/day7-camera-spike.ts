import { createHash } from 'node:crypto';
import { readdir, readFile, rm, stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { loadImage } from '@napi-rs/canvas';
import {
  CameraDiagnosticSink,
  writeCameraArtifacts,
} from '../src/compositor/camera-artifact-writer.js';
import { SequentialCameraEvaluator } from '../src/compositor/camera-evaluator.js';
import {
  type CameraRawRgbaFrame,
  CameraFrameCompositor,
  cameraCursorHotspot,
} from '../src/compositor/camera-frame-compositor.js';
import { projectCssPoint, sourceCropForCamera } from '../src/compositor/camera-projection.js';
import {
  cameraMotionStatistics,
  measureTargetFraming,
} from '../src/compositor/camera-statistics.js';
import { buildCameraTrack } from '../src/compositor/camera-track.js';
import type { TargetFramingMeasurement } from '../src/compositor/camera-types.js';
import { openCompositionPlan } from '../src/compositor/composition-plan-reader.js';
import { loadCursorAsset } from '../src/compositor/cursor-asset.js';
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
  readonly records: unknown[] = [];
  readonly pngHashes: string[] = [];
  readonly landing: CursorLandingMeasurement[] = [];
  private readonly rolling = createHash('sha256');

  constructor(
    private readonly compositor: CameraFrameCompositor,
    private readonly viewport: { width: number; height: number },
    private readonly landingEvents: ReadonlyMap<number, readonly ClickTimelineEvent[]>,
  ) {}

  async consume(rawFrame: RawRgbaFrame): Promise<void> {
    const frame = rawFrame as CameraRawRgbaFrame;
    const rgbaSha256 = createHash('sha256').update(frame.data).digest('hex');
    const pngSha256 = createHash('sha256').update(this.compositor.base.png()).digest('hex');
    this.rolling.update(frame.data);
    this.records.push({
      outputIndex: frame.outputIndex,
      rgbaSha256,
      camera: frame.camera,
      sourceCrop: frame.sourceCrop,
      cursor: frame.cursor,
    });
    this.pngHashes.push(pngSha256);
    for (const click of this.landingEvents.get(frame.outputIndex) ?? []) {
      this.landing.push(
        measureCursorLanding({
          click,
          outputFrame: frameRecord(frame),
          cursor: frame.cursor,
          cursorScreen: cameraCursorHotspot(frame),
          clickScreen: projectCssPoint(
            click.clickPoint,
            frame.camera,
            this.viewport,
            this.compositor.base.contentRect,
          ),
        }),
      );
    }
  }

  result() {
    return {
      records: this.records,
      pngHashes: this.pngHashes,
      landing: this.landing,
      digest: this.rolling.digest('hex'),
    };
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

async function* subsetFrames(
  planDirectory: string,
  indices: ReadonlySet<number>,
): AsyncGenerator<ResampledFrameRecord> {
  const plan = await openCompositionPlan(planDirectory);
  for await (const record of plan.frames()) if (indices.has(record.outputIndex)) yield record;
}

async function selectedRecords(
  planDirectory: string,
  indices: ReadonlySet<number>,
): Promise<Map<number, ResampledFrameRecord>> {
  const result = new Map<number, ResampledFrameRecord>();
  for await (const record of subsetFrames(planDirectory, indices)) result.set(record.outputIndex, record);
  if (result.size !== indices.size) throw new Error('Not every selected camera frame exists');
  return result;
}

function rssDiagnostics(samples: Array<{ frame: number; rssBytes: number }>) {
  const xMean = samples.reduce((sum, sample) => sum + sample.frame, 0) / samples.length;
  const yMean = samples.reduce((sum, sample) => sum + sample.rssBytes, 0) / samples.length;
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

function addPurpose(map: Map<number, string>, index: number, purpose: string): void {
  const existing = map.get(index);
  map.set(index, existing ? `${existing}; ${purpose}` : purpose);
}

async function artifactSize(directory: string): Promise<number> {
  let bytes = 0;
  for (const entry of await readdir(directory, { withFileTypes: true, recursive: true })) {
    if (entry.isFile()) bytes += (await stat(resolve(entry.parentPath, entry.name))).size;
  }
  return bytes;
}

async function runReplay(options: {
  planDirectory: string;
  captureDirectory: string;
  sourceWidth: number;
  sourceHeight: number;
  viewport: { width: number; height: number };
  timeline: TimelineDocument;
  durationMs: number;
  cursorFile: string;
  indices: ReadonlySet<number>;
  landingEvents: ReadonlyMap<number, readonly ClickTimelineEvent[]>;
}) {
  const cameraTrack = buildCameraTrack(
    options.timeline.events,
    options.durationMs,
    options.viewport,
  );
  const cursorTrack = buildCursorTrack(options.timeline.events, options.viewport);
  const compositor = new CameraFrameCompositor(
    options.sourceWidth,
    options.sourceHeight,
    options.viewport,
    await loadCursorAsset(options.cursorFile),
    new SequentialCameraEvaluator(cameraTrack),
    new SequentialCursorEvaluator(cursorTrack),
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
  return collector.result();
}

const planDirectory = resolve(process.argv[2] ?? '.tmp/day4-resampler-spike');
const outputDirectory = resolve(process.argv[3] ?? '.tmp/day7-camera-spike');
const cursorFile = resolve('assets/cursor.svg');
const temporaryRoot = resolve('.tmp');
if (!outputDirectory.startsWith(`${temporaryRoot}/`)) {
  throw new Error('Day-7 spike output must remain under the repository .tmp directory');
}
await rm(outputDirectory, { recursive: true, force: true });

const initialPlan = await openCompositionPlan(planDirectory);
const planManifest = initialPlan.manifest;
const captureDirectory = resolve(planManifest.sourceCapturePath);
const captureManifest = JSON.parse(
  await readFile(resolve(captureDirectory, 'manifest.json'), 'utf8'),
) as { captureDurationMs: number; viewport: { width: number; height: number } };
if (captureManifest.viewport.width !== 1440 || captureManifest.viewport.height !== 900) {
  throw new Error('Day-7 spike requires the 1440x900 CSS viewport');
}
if (planManifest.sourcePixelWidth !== 2880 || planManifest.sourcePixelHeight !== 1800) {
  throw new Error('Day-7 spike requires the accepted 2880x1800 source');
}
const timelinePath = resolve(captureDirectory, 'timeline.json');
const timeline = JSON.parse(await readFile(timelinePath, 'utf8')) as TimelineDocument;
validateTimelineDocument(timeline, captureManifest.captureDurationMs);
if (timeline.events.length !== 30) throw new Error('Day-7 spike requires 30 click events');

const cameraTrack = buildCameraTrack(
  timeline.events,
  planManifest.outputDurationMs,
  captureManifest.viewport,
);
const cursorTrack = buildCursorTrack(timeline.events, captureManifest.viewport);
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
const previewCamera = new SequentialCameraEvaluator(cameraTrack);
const previewCursor = new SequentialCursorEvaluator(cursorTrack);
const previewFraming: TargetFramingMeasurement[] = [];
const previewLanding: CursorLandingMeasurement[] = [];
for (const click of timeline.events) {
  const index = clickOutputIndices.get(click.id);
  const record = index === undefined ? undefined : clickFrames.get(index);
  if (!record) throw new Error(`Missing camera click frame for ${click.id}`);
  const camera = previewCamera.evaluate(record.outputTimestampMs);
  const cursor = previewCursor.evaluate(record.outputTimestampMs);
  if (!cursor.visible || cursor.cssX === undefined || cursor.cssY === undefined) {
    throw new Error(`${click.id} has no cursor at its camera landing frame`);
  }
  previewLanding.push(
    measureCursorLanding({
      click,
      outputFrame: record,
      cursor,
      cursorScreen: projectCssPoint(
        { x: cursor.cssX, y: cursor.cssY },
        camera,
        captureManifest.viewport,
        { x: 96, y: 0, width: 1728, height: 1080 },
      ),
      clickScreen: projectCssPoint(click.clickPoint, camera, captureManifest.viewport, {
        x: 96,
        y: 0,
        width: 1728,
        height: 1080,
      }),
    }),
  );
  previewFraming.push(
    measureTargetFraming({
      click,
      outputIndex: record.outputIndex,
      camera,
      viewport: captureManifest.viewport,
      contentRect: { x: 96, y: 0, width: 1728, height: 1080 },
    }),
  );
}

const firstTransition = cameraTrack.transitions[0];
if (!firstTransition) throw new Error('Camera track has no transitions');
const largestPan = cameraTrack.transitions.reduce((current, transition) =>
  Math.hypot(
    transition.to.centerCssX - transition.from.centerCssX,
    transition.to.centerCssY - transition.from.centerCssY,
  ) >
  Math.hypot(current.to.centerCssX - current.from.centerCssX, current.to.centerCssY - current.from.centerCssY)
    ? transition
    : current,
);
const worstFraming = previewFraming.reduce((current, measurement) =>
  measurement.visibleFraction < current.visibleFraction ||
  (measurement.visibleFraction === current.visibleFraction &&
    measurement.targetCenterDistanceFromContentCenterPx > current.targetCenterDistanceFromContentCenterPx)
    ? measurement
    : current,
);
const worstLandingId = cursorLandingStatistics(previewLanding).worstClickId;
const staticClick = timeline.events.find((event) => event.target.value.testId === 'static-target');
const hoverClick = timeline.events.find((event) => event.target.value.testId === 'hover-target');
if (!staticClick || !hoverClick) throw new Error('Camera snapshots require fixture target types');
const outputIndexAt = (timeMs: number) =>
  nearestOutputIndex(timeMs, planManifest.outputFrameCount, OUTPUT_FPS);
const snapshots = new Map<number, string>();
addPurpose(snapshots, 0, 'initial establishing frame');
addPurpose(snapshots, Math.ceil((firstTransition.startMs * OUTPUT_FPS) / 1000), 'first camera-transition frame');
addPurpose(snapshots, outputIndexAt((firstTransition.startMs + firstTransition.endMs) / 2), 'midpoint of first transition');
addPurpose(snapshots, Math.ceil((firstTransition.endMs * OUTPUT_FPS) / 1000), 'first target-focus frame');
addPurpose(snapshots, clickOutputIndices.get(staticClick.id) ?? -1, 'first static click');
addPurpose(snapshots, clickOutputIndices.get(hoverClick.id) ?? -1, 'first hover click');
addPurpose(snapshots, outputIndexAt((largestPan.startMs + largestPan.endMs) / 2), 'large pan between targets');
const maxZoomTransition = cameraTrack.transitions.reduce((current, transition) =>
  transition.to.zoom > current.to.zoom ? transition : current,
);
addPurpose(snapshots, Math.ceil((maxZoomTransition.endMs * OUTPUT_FPS) / 1000), 'maximum zoom frame');
addPurpose(snapshots, worstFraming.outputIndex, 'worst target-framing frame');
addPurpose(snapshots, clickOutputIndices.get(worstLandingId) ?? -1, 'worst landing-error frame');
addPurpose(snapshots, planManifest.outputFrameCount - 1, 'final frame');
if (snapshots.has(-1)) throw new Error('A camera snapshot could not be mapped');

const asset = await loadCursorAsset(cursorFile);
const compositor = new CameraFrameCompositor(
  planManifest.sourcePixelWidth,
  planManifest.sourcePixelHeight,
  captureManifest.viewport,
  asset,
  new SequentialCameraEvaluator(cameraTrack),
  new SequentialCursorEvaluator(cursorTrack),
  new Set(landingEvents.keys()),
);
const sink = await CameraDiagnosticSink.create({
  outputDirectory,
  compositor: compositor.base,
  viewport: captureManifest.viewport,
  source: { width: planManifest.sourcePixelWidth, height: planManifest.sourcePixelHeight },
  landingEvents,
  snapshotPurposes: snapshots,
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
        if ((index + 1) % 25 === 0) rssSamples.push({ frame: index + 1, rssBytes: process.memoryUsage().rss });
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
const landing = cursorLandingStatistics(sinkResult.landing);
const staticLanding = cursorLandingStatistics(
  sinkResult.landing.filter((measurement) => measurement.targetTestId === 'static-target'),
);
const hoverLanding = cursorLandingStatistics(
  sinkResult.landing.filter((measurement) => measurement.targetTestId === 'hover-target'),
);
const motion = cameraMotionStatistics({
  track: cameraTrack,
  states: sinkResult.cameraStates,
  framing: sinkResult.framing,
  viewport: captureManifest.viewport,
  contentRect: compositor.base.contentRect,
});

const subsetIndices = new Set<number>([
  0,
  Math.ceil((firstTransition.startMs * OUTPUT_FPS) / 1000),
  outputIndexAt((firstTransition.startMs + firstTransition.endMs) / 2),
  Math.ceil((firstTransition.endMs * OUTPUT_FPS) / 1000),
  Math.min(planManifest.outputFrameCount - 1, Math.ceil((firstTransition.endMs * OUTPUT_FPS) / 1000) + 1),
  clickOutputIndices.get(staticClick.id) ?? -1,
  clickOutputIndices.get(hoverClick.id) ?? -1,
  Math.ceil((maxZoomTransition.endMs * OUTPUT_FPS) / 1000),
  planManifest.outputFrameCount - 1,
]);
subsetIndices.delete(-1);
const replayLandingEvents = new Map<number, readonly ClickTimelineEvent[]>();
for (const [index, events] of landingEvents) if (subsetIndices.has(index)) replayLandingEvents.set(index, events);
const replayOptions = {
  planDirectory,
  captureDirectory,
  sourceWidth: planManifest.sourcePixelWidth,
  sourceHeight: planManifest.sourcePixelHeight,
  viewport: captureManifest.viewport,
  timeline,
  durationMs: planManifest.outputDurationMs,
  cursorFile,
  indices: subsetIndices,
  landingEvents: replayLandingEvents,
};
const firstReplay = await runReplay(replayOptions);
const secondReplay = await runReplay(replayOptions);
const deterministicReplay = JSON.stringify(firstReplay) === JSON.stringify(secondReplay);

const transitions = cameraTrack.transitions.map((transition) => ({
  id: transition.id,
  clickId: transition.clickId,
  startMs: transition.startMs,
  endMs: transition.endMs,
  durationMs: transition.endMs - transition.startMs,
  from: transition.from,
  to: transition.to,
  compressed: transition.compressed,
  outputFrames: Math.max(1, Math.floor((transition.endMs * OUTPUT_FPS) / 1000) - Math.ceil((transition.startMs * OUTPUT_FPS) / 1000) + 1),
}));
const mouseDownCameraStates = sinkResult.framing.map((measurement) => ({
  clickId: measurement.clickId,
  outputIndex: measurement.outputIndex,
  zoom: measurement.zoom,
  centerCssX: measurement.cameraCenterCssX,
  centerCssY: measurement.cameraCenterCssY,
}));
const performanceResult = {
  executionMs,
  framesPerSecond: run.framesProcessed / (executionMs / 1000),
  rssBeforeBytes,
  rssAfterBytes,
  peakRssBytes: memory.peakRssBytes,
  rssSlopeBytesPerFrame: memory.slopeBytesPerFrame,
};
const manifest = {
  schemaVersion: 1,
  sourceCapturePath: captureDirectory,
  sourceResamplePlanPath: planDirectory,
  sourceTimelinePath: timelinePath,
  sourcePixelWidth: planManifest.sourcePixelWidth,
  sourcePixelHeight: planManifest.sourcePixelHeight,
  outputWidth: OUTPUT_WIDTH,
  outputHeight: OUTPUT_HEIGHT,
  outputFps: OUTPUT_FPS,
  outputFrameCount: run.framesProcessed,
  cssViewport: captureManifest.viewport,
  contentRect: compositor.base.contentRect,
  camera: {
    coordinateSpace: 'css-viewport',
    easing: [0.22, 1, 0.36, 1],
    policy: 'studio-day7',
    motion,
    transitions,
    mouseDownCameraStates,
    cropSafetyCorrections: sinkResult.cropSafetyCorrections,
  },
  cursor: {
    assetFile: 'assets/cursor.svg',
    assetSha256: asset.sha256,
    ...asset.definition,
    coordinateSpace: 'output-screen',
  },
  cursorTrack: {
    clickEvents: timeline.events.length,
    pathPoints: cursorTrack.pointCount,
    firstPointMs: cursorTrack.firstPointMs,
    lastPointMs: cursorTrack.lastPointMs,
  },
  cursorFrames: sinkResult.cursorFrames,
  landing,
  staticLanding,
  hoverLanding,
  targetFraming: motion.targetFraming,
  decoding: run.sourceImages,
  bytesProcessed: run.bytesProcessed,
  rollingRgbaSha256: sinkResult.rollingRgbaSha256,
  performance: performanceResult,
  snapshots: sinkResult.snapshots,
};
await writeCameraArtifacts({
  outputDirectory,
  manifest,
  cameraTrack,
  landing: sinkResult.landing,
  framing: sinkResult.framing,
});

const hashLines = (await readFile(resolve(outputDirectory, 'frame-hashes.jsonl'), 'utf8')).trim().split('\n').length;
const snapshotDimensions = await Promise.all(
  sinkResult.snapshots.map(async (snapshot) => {
    const image = await loadImage(resolve(outputDirectory, snapshot.file));
    return { file: snapshot.file, width: image.width, height: image.height };
  }),
);
const framingPass = sinkResult.framing.every(
  (measurement) => Math.abs(measurement.visibleFraction - 1) <= 1e-7 && measurement.clickPointInsideProjectedTarget,
);
const passed =
  run.framesProcessed === planManifest.outputFrameCount &&
  hashLines === planManifest.outputFrameCount &&
  sinkResult.landing.length === 30 &&
  cursorLandingGatePasses(landing) &&
  framingPass &&
  sinkResult.cropSafetyCorrections === 0 &&
  run.maxActiveFrames <= 1 &&
  run.sourceImages.maxDecodedImagesRetained <= 1 &&
  memory.peakRssBytes < 1024 ** 3 &&
  memory.slopeBytesPerFrame < 128 * 1024 &&
  deterministicReplay &&
  snapshotDimensions.every((snapshot) => snapshot.width === 1920 && snapshot.height === 1080);
const summary = {
  passed,
  outputFrameCount: run.framesProcessed,
  camera: { motion, transitions, mouseDownCameraStates },
  targetFraming: sinkResult.framing,
  landing,
  staticLanding,
  hoverLanding,
  landingMeasurements: sinkResult.landing,
  cursorTrack: manifest.cursorTrack,
  cursorFrames: sinkResult.cursorFrames,
  cursorRaster: { width: asset.definition.renderedWidth, height: asset.definition.renderedHeight },
  cropSafety: { corrections: sinkResult.cropSafetyCorrections, unsafeFrames: 0 },
  bytesProcessed: run.bytesProcessed,
  rollingRgbaSha256: sinkResult.rollingRgbaSha256,
  decoding: run.sourceImages,
  performance: performanceResult,
  warnings: {
    throughputBelow15Fps: performanceResult.framesPerSecond < 15,
    peakRssMoreThanTwiceDay6: performanceResult.peakRssBytes > 2 * 186_662_912,
  },
  deterministicSubset: {
    indices: [...subsetIndices].sort((left, right) => left - right),
    firstDigest: firstReplay.digest,
    secondDigest: secondReplay.digest,
    identical: deterministicReplay,
  },
  artifact: {
    hashLines,
    artifactSizeBytes: await artifactSize(outputDirectory),
    snapshots: snapshotDimensions,
  },
};
process.stderr.write(
  [
    'Day 7 camera spike',
    `frames       ${run.framesProcessed} at ${performanceResult.framesPerSecond.toFixed(2)} fps`,
    `camera       ${motion.transitionCount} transitions / ${motion.compressedTransitionCount} compressed / ${motion.zoom.max.toFixed(3)}x max`,
    `framing      ${motion.targetFraming.fullyVisibleCount} fully visible / ${motion.targetFraming.clippedCount} clipped`,
    `landing      median ${landing.distanceOutputPx.median.toFixed(3)} px / p95 ${landing.distanceOutputPx.p95.toFixed(3)} px / max ${landing.distanceOutputPx.max.toFixed(3)} px`,
    `memory       ${(rssBeforeBytes / 1024 ** 2).toFixed(1)} MiB before / ${(memory.peakRssBytes / 1024 ** 2).toFixed(1)} MiB peak / ${(rssAfterBytes / 1024 ** 2).toFixed(1)} MiB after`,
    `replay       ${deterministicReplay ? 'identical' : 'mismatch'}`,
    `result       ${passed ? 'PASS' : 'FAIL'}`,
    '',
  ].join('\n'),
);
process.stdout.write(`${JSON.stringify(summary)}\n`);
if (!passed) process.exitCode = 1;
