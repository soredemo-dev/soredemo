import { createHash } from 'node:crypto';
import { mkdir, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { createCanvas, loadImage } from '@napi-rs/canvas';
import { SequentialCameraEvaluator } from '../src/compositor/camera-evaluator.js';
import { projectCssPoint } from '../src/compositor/camera-projection.js';
import {
  cameraMotionStatistics,
  measureTargetFraming,
} from '../src/compositor/camera-statistics.js';
import { buildCameraTrack } from '../src/compositor/camera-track.js';
import type { CameraFrameState } from '../src/compositor/camera-types.js';
import {
  buildClickFeedbackTrack,
  CLICK_RIPPLE_STYLE,
  SequentialClickFeedbackEvaluator,
} from '../src/compositor/click-feedback-track.js';
import { openCompositionPlan } from '../src/compositor/composition-plan-reader.js';
import { loadCursorAsset } from '../src/compositor/cursor-asset.js';
import { SequentialCursorEvaluator } from '../src/compositor/cursor-track.js';
import { runComposition } from '../src/compositor/frame-runner.js';
import {
  cursorLandingGatePasses,
  cursorLandingStatistics,
  measureCursorLanding,
} from '../src/compositor/landing-statistics.js';
import { SequentialSourceImageLoader } from '../src/compositor/source-image-loader.js';
import {
  StudioDiagnosticSink,
  writeStudioArtifacts,
} from '../src/compositor/studio-artifact-writer.js';
import {
  StudioFrameCompositor,
  type StudioRawRgbaFrame,
  studioCursorHotspot,
} from '../src/compositor/studio-frame-compositor.js';
import {
  STUDIO_BROWSER_CONTENT_RECT,
  STUDIO_BROWSER_WINDOW_RECT,
  STUDIO_GRADIENT,
  STUDIO_TOOLBAR,
  STUDIO_TOOLBAR_HEIGHT,
  STUDIO_TRAFFIC_LIGHTS,
  STUDIO_WINDOW_BORDER,
  STUDIO_WINDOW_RADIUS,
  STUDIO_WINDOW_SHADOW,
  validateStudioLayout,
} from '../src/compositor/studio-layout.js';
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
  private readonly rolling = createHash('sha256');

  constructor(
    private readonly compositor: StudioFrameCompositor,
    private readonly viewport: { width: number; height: number },
    private readonly landingEvents: ReadonlyMap<number, readonly ClickTimelineEvent[]>,
  ) {}

  async consume(rawFrame: RawRgbaFrame): Promise<void> {
    const frame = rawFrame as StudioRawRgbaFrame;
    const landing = [];
    for (const click of this.landingEvents.get(frame.outputIndex) ?? []) {
      landing.push(
        measureCursorLanding({
          click,
          outputFrame: asResampleRecord(frame),
          cursor: frame.cursor,
          cursorScreen: studioCursorHotspot(frame),
          clickScreen: projectCssPoint(
            click.clickPoint,
            frame.camera,
            this.viewport,
            STUDIO_BROWSER_CONTENT_RECT,
          ),
        }),
      );
    }
    const rgbaSha256 = createHash('sha256').update(frame.data).digest('hex');
    const pngSha256 = createHash('sha256').update(this.compositor.png()).digest('hex');
    this.rolling.update(frame.data);
    this.records.push({
      outputIndex: frame.outputIndex,
      rgbaSha256,
      camera: frame.camera,
      sourceCrop: frame.sourceCrop,
      cursor: frame.cursor,
      ripples: frame.ripples,
      landing,
    });
    this.pngHashes.push(pngSha256);
  }

  result() {
    return {
      records: this.records,
      pngHashes: this.pngHashes,
      digest: this.rolling.digest('hex'),
    };
  }
}

function asResampleRecord(frame: RawRgbaFrame): ResampledFrameRecord {
  const delta = frame.sourceTimestampMs - frame.outputTimestampMs;
  return {
    outputIndex: frame.outputIndex,
    outputTimestampMs: frame.outputTimestampMs,
    sourceIndex: frame.sourceIndex,
    sourceFile: '',
    sourceTimestampMs: frame.sourceTimestampMs,
    signedSourceDeltaMs: delta,
    absoluteSourceDeltaMs: Math.abs(delta),
    relation: delta < 0 ? 'before' : delta > 0 ? 'after' : 'exact',
  };
}

async function allRecords(planDirectory: string): Promise<ResampledFrameRecord[]> {
  const plan = await openCompositionPlan(planDirectory);
  const records: ResampledFrameRecord[] = [];
  for await (const record of plan.frames()) records.push(record);
  return records;
}

async function* selectedFrames(
  records: readonly ResampledFrameRecord[],
  indices?: ReadonlySet<number>,
): AsyncGenerator<ResampledFrameRecord> {
  for (const record of records) if (!indices || indices.has(record.outputIndex)) yield record;
}

function rssDiagnostics(samples: Array<{ frame: number; rssBytes: number }>) {
  const xMean = samples.reduce((sum, item) => sum + item.frame, 0) / samples.length;
  const yMean = samples.reduce((sum, item) => sum + item.rssBytes, 0) / samples.length;
  let numerator = 0;
  let denominator = 0;
  for (const item of samples) {
    numerator += (item.frame - xMean) * (item.rssBytes - yMean);
    denominator += (item.frame - xMean) ** 2;
  }
  return {
    peakRssBytes: Math.max(...samples.map((item) => item.rssBytes)),
    slopeBytesPerFrame: denominator === 0 ? 0 : numerator / denominator,
  };
}

function addPurpose(map: Map<number, string>, index: number, purpose: string): void {
  const existing = map.get(index);
  map.set(index, existing ? `${existing}; ${purpose}` : purpose);
}

async function artifactSize(directory: string): Promise<number> {
  let bytes = 0;
  for (const entry of await readdir(directory, { recursive: true, withFileTypes: true })) {
    if (entry.isFile()) bytes += (await stat(resolve(entry.parentPath, entry.name))).size;
  }
  return bytes;
}

async function runReplay(options: {
  records: readonly ResampledFrameRecord[];
  indices: ReadonlySet<number>;
  captureDirectory: string;
  sourceWidth: number;
  sourceHeight: number;
  viewport: { width: number; height: number };
  timeline: TimelineDocument;
  durationMs: number;
  cursorFile: string;
  landingEvents: ReadonlyMap<number, readonly ClickTimelineEvent[]>;
}) {
  const compositor = new StudioFrameCompositor(
    options.sourceWidth,
    options.sourceHeight,
    options.viewport,
    await loadCursorAsset(options.cursorFile),
    new SequentialCameraEvaluator(
      buildCameraTrack(options.timeline.events, options.durationMs, options.viewport),
    ),
    new SequentialCursorEvaluator(buildCursorTrack(options.timeline.events, options.viewport)),
    new SequentialClickFeedbackEvaluator(buildClickFeedbackTrack(options.timeline.events)),
    new Set(options.landingEvents.keys()),
  );
  const collector = new ReplayCollector(compositor, options.viewport, options.landingEvents);
  await runComposition({
    frames: selectedFrames(options.records, options.indices),
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

async function writeContactSheet(outputDirectory: string, snapshotFiles: readonly string[]) {
  const images = await Promise.all(
    snapshotFiles.map((file) => loadImage(resolve(outputDirectory, file))),
  );
  const columns = 3;
  const cellWidth = 320;
  const cellHeight = 180;
  const gap = 8;
  const rows = Math.ceil(images.length / columns);
  const canvas = createCanvas(
    columns * cellWidth + (columns + 1) * gap,
    rows * cellHeight + (rows + 1) * gap,
  );
  const context = canvas.getContext('2d');
  context.fillStyle = '#E5E7EB';
  context.fillRect(0, 0, canvas.width, canvas.height);
  for (const [index, image] of images.entries()) {
    const column = index % columns;
    const row = Math.floor(index / columns);
    context.drawImage(
      image,
      gap + column * (cellWidth + gap),
      gap + row * (cellHeight + gap),
      cellWidth,
      cellHeight,
    );
  }
  const png = canvas.toBuffer('image/png');
  const file = 'snapshots/contact-sheet.png';
  await writeFile(resolve(outputDirectory, file), png, { flag: 'wx' });
  return {
    file,
    width: canvas.width,
    height: canvas.height,
    pngSha256: createHash('sha256').update(png).digest('hex'),
  };
}

validateStudioLayout();
const planDirectory = resolve(process.argv[2] ?? '.tmp/day4-resampler-spike');
const outputDirectory = resolve(process.argv[3] ?? '.tmp/day8-studio-composition');
const temporaryRoot = resolve('.tmp');
if (!outputDirectory.startsWith(`${temporaryRoot}/`)) {
  throw new Error('Day-8 output must remain under the repository .tmp directory');
}
await rm(outputDirectory, { recursive: true, force: true });
await mkdir(outputDirectory, { recursive: true });
const cursorFile = resolve('assets/cursor.svg');
const plan = await openCompositionPlan(planDirectory);
const planManifest = plan.manifest;
const records = await allRecords(planDirectory);
const captureDirectory = resolve(planManifest.sourceCapturePath);
const captureManifest = JSON.parse(
  await readFile(resolve(captureDirectory, 'manifest.json'), 'utf8'),
) as { captureDurationMs: number; viewport: { width: number; height: number } };
if (
  captureManifest.viewport.width !== 1440 ||
  captureManifest.viewport.height !== 900 ||
  planManifest.sourcePixelWidth !== 2880 ||
  planManifest.sourcePixelHeight !== 1800
) {
  throw new Error('Day-8 composition requires the accepted viewport and source dimensions');
}
const timeline = JSON.parse(
  await readFile(resolve(captureDirectory, 'timeline.json'), 'utf8'),
) as TimelineDocument;
validateTimelineDocument(timeline, captureManifest.captureDurationMs);
if (timeline.events.length !== 30) throw new Error('Day-8 composition requires 30 clicks');
const clicks = timeline.events.filter((event) => event.kind === 'click');

const cameraTrack = buildCameraTrack(
  timeline.events,
  planManifest.outputDurationMs,
  captureManifest.viewport,
);
const cursorTrack = buildCursorTrack(timeline.events, captureManifest.viewport);
const feedbackTrack = buildClickFeedbackTrack(timeline.events);
const clickOutputIndices = new Map<string, number>();
const landingEvents = new Map<number, ClickTimelineEvent[]>();
for (const click of clicks) {
  const index = nearestOutputIndex(click.mouseDownMs, planManifest.outputFrameCount, OUTPUT_FPS);
  clickOutputIndices.set(click.id, index);
  const events = landingEvents.get(index) ?? [];
  events.push(click);
  landingEvents.set(index, events);
}

const previewCamera = new SequentialCameraEvaluator(cameraTrack);
let previousCamera: ReturnType<typeof previewCamera.evaluate> | undefined;
let worstMotionIndex = 0;
let worstMotion = 0;
const previewStates: CameraFrameState[] = [];
for (const record of records) {
  const state = previewCamera.evaluate(record.outputTimestampMs);
  previewStates.push(state);
  if (previousCamera) {
    const movement = Math.hypot(
      state.centerCssX - previousCamera.centerCssX,
      state.centerCssY - previousCamera.centerCssY,
    );
    if (movement > worstMotion) {
      worstMotion = movement;
      worstMotionIndex = record.outputIndex;
    }
  }
  previousCamera = state;
}
const previewFraming = clicks.map((click) => {
  const outputIndex = clickOutputIndices.get(click.id);
  if (outputIndex === undefined) throw new Error(`Missing output index for ${click.id}`);
  const camera = previewStates[outputIndex];
  if (!camera) throw new Error(`Missing camera state for ${click.id}`);
  return measureTargetFraming({
    click,
    outputIndex,
    camera,
    viewport: captureManifest.viewport,
    contentRect: STUDIO_BROWSER_CONTENT_RECT,
  });
});
const worstFraming = previewFraming.reduce((current, item) =>
  item.visibleFraction < current.visibleFraction ||
  (item.visibleFraction === current.visibleFraction &&
    item.targetCenterDistanceFromContentCenterPx > current.targetCenterDistanceFromContentCenterPx)
    ? item
    : current,
);
const firstTransition = cameraTrack.transitions[0];
const largestPan = cameraTrack.transitions.reduce((current, item) =>
  Math.hypot(item.to.centerCssX - item.from.centerCssX, item.to.centerCssY - item.from.centerCssY) >
  Math.hypot(
    current.to.centerCssX - current.from.centerCssX,
    current.to.centerCssY - current.from.centerCssY,
  )
    ? item
    : current,
);
const maxZoomTransition = cameraTrack.transitions.reduce((current, item) =>
  item.to.zoom > current.to.zoom ? item : current,
);
if (!firstTransition) throw new Error('Day-8 camera track has no transition');
const staticClick = clicks.find((item) => item.target.value.testId === 'static-target');
const hoverClick = clicks.find((item) => item.target.value.testId === 'hover-target');
if (!staticClick || !hoverClick) throw new Error('Day-8 snapshots require fixture target types');
const nearestIndex = (timeMs: number) =>
  nearestOutputIndex(timeMs, planManifest.outputFrameCount, OUTPUT_FPS);
const firstFrameAtOrAfter = (timeMs: number) =>
  Math.min(planManifest.outputFrameCount - 1, Math.ceil((timeMs * OUTPUT_FPS) / 1000));
const frameBefore = (timeMs: number) => Math.max(0, Math.ceil((timeMs * OUTPUT_FPS) / 1000) - 1);
const snapshots = new Map<number, string>();
addPurpose(snapshots, 0, 'initial establishing frame');
addPurpose(
  snapshots,
  nearestIndex((firstTransition.startMs + firstTransition.endMs) / 2),
  'midpoint of first camera move',
);
addPurpose(snapshots, frameBefore(staticClick.mouseDownMs), 'first static click before ripple');
addPurpose(
  snapshots,
  firstFrameAtOrAfter(staticClick.mouseDownMs),
  'first static click with ripple',
);
addPurpose(snapshots, firstFrameAtOrAfter(hoverClick.mouseDownMs), 'first hover click with ripple');
addPurpose(
  snapshots,
  nearestIndex((largestPan.startMs + largestPan.endMs) / 2),
  'large pan between targets',
);
addPurpose(snapshots, firstFrameAtOrAfter(maxZoomTransition.endMs), 'maximum zoom frame');
addPurpose(snapshots, worstMotionIndex, 'worst camera-motion frame');
addPurpose(snapshots, worstFraming.outputIndex, 'worst target-framing frame');
addPurpose(snapshots, planManifest.outputFrameCount - 1, 'final frame');

const asset = await loadCursorAsset(cursorFile);
const compositor = new StudioFrameCompositor(
  planManifest.sourcePixelWidth,
  planManifest.sourcePixelHeight,
  captureManifest.viewport,
  asset,
  new SequentialCameraEvaluator(cameraTrack),
  new SequentialCursorEvaluator(cursorTrack),
  new SequentialClickFeedbackEvaluator(feedbackTrack),
  new Set(landingEvents.keys()),
);
const sink = await StudioDiagnosticSink.create({
  outputDirectory,
  compositor,
  viewport: captureManifest.viewport,
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
    const run = await runComposition({
      frames: selectedFrames(records),
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
const landing = cursorLandingStatistics(sinkResult.landing);
const motion = cameraMotionStatistics({
  track: cameraTrack,
  states: previewStates,
  framing: sinkResult.framing,
  viewport: captureManifest.viewport,
  contentRect: STUDIO_BROWSER_CONTENT_RECT,
});
const snapshotDimensions = await Promise.all(
  sinkResult.snapshots.map(async (snapshot) => {
    const image = await loadImage(resolve(outputDirectory, snapshot.file));
    return { file: snapshot.file, width: image.width, height: image.height };
  }),
);
const contactSheet = await writeContactSheet(
  outputDirectory,
  sinkResult.snapshots.map((snapshot) => snapshot.file),
);

const staticRippleIndex = firstFrameAtOrAfter(staticClick.mouseDownMs);
const hoverRippleIndex = firstFrameAtOrAfter(hoverClick.mouseDownMs);
const rippleMidIndex = firstFrameAtOrAfter(
  staticClick.mouseDownMs + CLICK_RIPPLE_STYLE.durationMs / 2,
);
const rippleEndIndex = firstFrameAtOrAfter(staticClick.mouseDownMs + CLICK_RIPPLE_STYLE.durationMs);
const subsetIndices = new Set([
  0,
  nearestIndex((firstTransition.startMs + firstTransition.endMs) / 2),
  firstFrameAtOrAfter(firstTransition.endMs),
  staticRippleIndex,
  rippleMidIndex,
  rippleEndIndex,
  hoverRippleIndex,
  worstMotionIndex,
  planManifest.outputFrameCount - 1,
]);
const replayLandingEvents = new Map<number, readonly ClickTimelineEvent[]>();
for (const [index, events] of landingEvents) {
  if (subsetIndices.has(index)) replayLandingEvents.set(index, events);
}
const replayOptions = {
  records,
  indices: subsetIndices,
  captureDirectory,
  sourceWidth: planManifest.sourcePixelWidth,
  sourceHeight: planManifest.sourcePixelHeight,
  viewport: captureManifest.viewport,
  timeline,
  durationMs: planManifest.outputDurationMs,
  cursorFile,
  landingEvents: replayLandingEvents,
};
const replayOne = await runReplay(replayOptions);
const replayTwo = await runReplay(replayOptions);
const deterministicReplay = JSON.stringify(replayOne) === JSON.stringify(replayTwo);
const performanceResult = {
  executionMs,
  framesPerSecond: run.framesProcessed / (executionMs / 1000),
  rssBeforeBytes,
  peakRssBytes: memory.peakRssBytes,
  rssAfterBytes,
  rssSlopeBytesPerFrame: memory.slopeBytesPerFrame,
};
const manifest = {
  schemaVersion: 1,
  output: {
    width: OUTPUT_WIDTH,
    height: OUTPUT_HEIGHT,
    fps: OUTPUT_FPS,
    frameCount: run.framesProcessed,
    pixelFormat: 'rgba',
    alphaMode: 'opaque',
  },
  background: { type: 'linear-gradient', ...STUDIO_GRADIENT },
  window: {
    outerRect: STUDIO_BROWSER_WINDOW_RECT,
    contentRect: STUDIO_BROWSER_CONTENT_RECT,
    toolbarHeight: STUDIO_TOOLBAR_HEIGHT,
    cornerRadius: STUDIO_WINDOW_RADIUS,
    border: STUDIO_WINDOW_BORDER,
    shadow: STUDIO_WINDOW_SHADOW,
    toolbar: STUDIO_TOOLBAR,
    trafficLights: {
      radius: STUDIO_TRAFFIC_LIGHTS.radius,
      centerY: STUDIO_TRAFFIC_LIGHTS.centerY,
      centersX: STUDIO_TRAFFIC_LIGHTS.centersX,
      colors: STUDIO_TRAFFIC_LIGHTS.colors,
    },
  },
  clickFeedback: { ...CLICK_RIPPLE_STYLE, ...sinkResult.ripple },
  cursor: {
    assetSha256: asset.sha256,
    renderedWidth: asset.definition.renderedWidth,
    renderedHeight: asset.definition.renderedHeight,
    hotspotX: asset.definition.hotspotX,
    hotspotY: asset.definition.hotspotY,
  },
  camera: {
    segmentCount: cameraTrack.segments.length,
    transitionCount: cameraTrack.transitions.length,
    compressedTransitionCount: cameraTrack.transitions.filter((item) => item.compressed).length,
    motion,
    cropSafety: { unsafeFrames: 0, correctedFrames: 0 },
  },
  landing,
  targetFraming: motion.targetFraming,
  mask: {
    leakFrames: sinkResult.maskLeakFrames,
    blackOutsideWindowFrames: sinkResult.blackOutsideWindowFrames,
  },
  decoding: run.sourceImages,
  bytesProcessed: run.bytesProcessed,
  rollingRgbaSha256: sinkResult.rollingRgbaSha256,
  performance: performanceResult,
  snapshots: sinkResult.snapshots,
  contactSheet,
};
await writeStudioArtifacts({
  outputDirectory,
  manifest,
  landing: sinkResult.landing,
  framing: sinkResult.framing,
  ripples: sinkResult.rippleMeasurements,
});
const hashLines = (await readFile(resolve(outputDirectory, 'frame-hashes.jsonl'), 'utf8'))
  .trim()
  .split('\n').length;
const framingPass = sinkResult.framing.every(
  (item) => Math.abs(item.visibleFraction - 1) <= 1e-7 && item.clickPointInsideProjectedTarget,
);
const passed =
  run.framesProcessed === planManifest.outputFrameCount &&
  hashLines === planManifest.outputFrameCount &&
  sinkResult.landing.length === 30 &&
  cursorLandingGatePasses(landing) &&
  framingPass &&
  sinkResult.ripple.ripplesStarted === 30 &&
  sinkResult.ripple.maxSimultaneousRipples >= 1 &&
  sinkResult.maskLeakFrames === 0 &&
  sinkResult.blackOutsideWindowFrames === 0 &&
  run.maxActiveFrames <= 1 &&
  run.sourceImages.maxDecodedImagesRetained <= 1 &&
  memory.peakRssBytes < 1024 ** 3 &&
  memory.slopeBytesPerFrame < 128 * 1024 &&
  deterministicReplay &&
  snapshotDimensions.every((item) => item.width === 1920 && item.height === 1080);
const summary = {
  passed,
  outputFrames: run.framesProcessed,
  studio: manifest.window,
  background: manifest.background,
  ripple: sinkResult.ripple,
  landing,
  targetFraming: motion.targetFraming,
  camera: { motion, cropSafety: manifest.camera.cropSafety },
  mask: manifest.mask,
  bytesProcessed: run.bytesProcessed,
  rollingRgbaSha256: sinkResult.rollingRgbaSha256,
  decoding: run.sourceImages,
  performance: performanceResult,
  warnings: {
    throughputBelow15Fps: performanceResult.framesPerSecond < 15,
    peakRssAbove400MiB: performanceResult.peakRssBytes > 400 * 1024 ** 2,
  },
  deterministicSubset: {
    indices: [...subsetIndices].sort((left, right) => left - right),
    firstDigest: replayOne.digest,
    secondDigest: replayTwo.digest,
    identical: deterministicReplay,
  },
  artifact: {
    hashLines,
    sizeBytes: await artifactSize(outputDirectory),
    snapshots: snapshotDimensions,
    contactSheet,
  },
};
process.stderr.write(
  [
    'Day 8 studio composition',
    `frames       ${run.framesProcessed} at ${performanceResult.framesPerSecond.toFixed(2)} fps`,
    `ripples      ${sinkResult.ripple.ripplesStarted} started / ${sinkResult.ripple.visibleFrameCount} visible frames / ${sinkResult.ripple.maxSimultaneousRipples} max active`,
    `framing      ${motion.targetFraming.fullyVisibleCount} fully visible / ${motion.targetFraming.clippedCount} clipped`,
    `landing      median ${landing.distanceOutputPx.median.toFixed(3)} px / p95 ${landing.distanceOutputPx.p95.toFixed(3)} px / max ${landing.distanceOutputPx.max.toFixed(3)} px`,
    `mask         ${sinkResult.maskLeakFrames} leak frames / ${sinkResult.blackOutsideWindowFrames} black-background frames`,
    `memory       ${(rssBeforeBytes / 1024 ** 2).toFixed(1)} MiB before / ${(memory.peakRssBytes / 1024 ** 2).toFixed(1)} MiB peak / ${(rssAfterBytes / 1024 ** 2).toFixed(1)} MiB after`,
    `replay       ${deterministicReplay ? 'identical' : 'mismatch'}`,
    `result       ${passed ? 'PASS' : 'FAIL'}`,
    '',
  ].join('\n'),
);
process.stdout.write(`${JSON.stringify(summary)}\n`);
if (!passed) process.exitCode = 1;
