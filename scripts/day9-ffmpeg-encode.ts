import { createHash } from 'node:crypto';
import { mkdir, readdir, readFile, rm, unlink, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { createCanvas, ImageData } from '@napi-rs/canvas';
import { SequentialCameraEvaluator } from '../src/compositor/camera-evaluator.js';
import { buildCameraTrack } from '../src/compositor/camera-track.js';
import {
  buildClickFeedbackTrack,
  SequentialClickFeedbackEvaluator,
} from '../src/compositor/click-feedback-track.js';
import { openCompositionPlan } from '../src/compositor/composition-plan-reader.js';
import { loadCursorAsset } from '../src/compositor/cursor-asset.js';
import { SequentialCursorEvaluator } from '../src/compositor/cursor-track.js';
import { runComposition } from '../src/compositor/frame-runner.js';
import { SequentialSourceImageLoader } from '../src/compositor/source-image-loader.js';
import { StudioFrameCompositor } from '../src/compositor/studio-frame-compositor.js';
import {
  type FrameConsumer,
  OUTPUT_FPS,
  OUTPUT_HEIGHT,
  OUTPUT_WIDTH,
  type RawRgbaFrame,
  RGBA_BYTE_LENGTH,
} from '../src/compositor/types.js';
import { resolveExecutable, resolveFfprobe } from '../src/encoder/executable-resolver.js';
import { FfmpegEncoder } from '../src/encoder/ffmpeg-encoder.js';
import { inspectFfmpeg } from '../src/encoder/ffmpeg-preflight.js';
import { validateEncodedVideo } from '../src/encoder/ffprobe-validation.js';
import { requireSuccessfulProcess, runCapturedProcess } from '../src/encoder/subprocess.js';
import type { ResolvedExecutable, ValidatedVideo } from '../src/encoder/types.js';
import { measureRgbaFidelity } from '../src/encoder/visual-fidelity.js';
import type { ResampledFrameRecord } from '../src/resample/types.js';
import { buildCursorTrack } from '../src/timeline/cursor-track-validation.js';
import type { TimelineDocument } from '../src/timeline/types.js';
import { validateTimelineDocument } from '../src/timeline/validation.js';

const planDirectory = resolve(process.argv[2] ?? '.tmp/day4-resampler-spike');
const day8Directory = resolve(process.argv[3] ?? '.tmp/day8-studio-composition');
const outputDirectory = resolve(process.argv[4] ?? '.tmp/day9-ffmpeg-encode');
const temporaryRoot = resolve('.tmp');
if (!outputDirectory.startsWith(`${temporaryRoot}/`)) {
  throw new Error('Day-9 output must remain under the repository .tmp directory');
}
await rm(outputDirectory, { recursive: true, force: true });
await mkdir(resolve(outputDirectory, 'fidelity'), { recursive: true });

const ffmpeg = await resolveExecutable({
  name: 'ffmpeg',
  environmentVariable: 'SOREDEMO_FFMPEG_PATH',
});
const ffprobe = await resolveFfprobe(ffmpeg);
const capabilities = await inspectFfmpeg(ffmpeg, ffprobe);
await Promise.all([
  writeFile(resolve(outputDirectory, 'ffmpeg-version.txt'), `${capabilities.raw.version}\n`),
  writeFile(resolve(outputDirectory, 'ffmpeg-buildconf.txt'), `${capabilities.raw.buildconf}\n`),
  writeFile(resolve(outputDirectory, 'ffmpeg-encoders.txt'), `${capabilities.raw.encoders}\n`),
  writeFile(resolve(outputDirectory, 'ffmpeg-formats.txt'), `${capabilities.raw.formats}\n`),
]);

const plan = await openCompositionPlan(planDirectory);
const planManifest = plan.manifest;
const records: ResampledFrameRecord[] = [];
for await (const record of plan.frames()) records.push(record);
const captureDirectory = resolve(planManifest.sourceCapturePath);
const captureManifest = JSON.parse(
  await readFile(resolve(captureDirectory, 'manifest.json'), 'utf8'),
) as { captureDurationMs: number; viewport: { width: number; height: number } };
if (
  captureManifest.viewport.width !== 1440 ||
  captureManifest.viewport.height !== 900 ||
  planManifest.sourcePixelWidth !== 2880 ||
  planManifest.sourcePixelHeight !== 1800 ||
  planManifest.outputFps !== OUTPUT_FPS
) {
  throw new Error('Day-9 encoding requires the accepted capture and output geometry');
}
const timeline = JSON.parse(
  await readFile(resolve(captureDirectory, 'timeline.json'), 'utf8'),
) as TimelineDocument;
validateTimelineDocument(timeline, captureManifest.captureDurationMs);
const day8Manifest = JSON.parse(
  await readFile(resolve(day8Directory, 'manifest.json'), 'utf8'),
) as { output: { frameCount: number }; rollingRgbaSha256: string };
if (day8Manifest.output.frameCount !== planManifest.outputFrameCount) {
  throw new Error('Day-8 manifest frame count does not match the resample plan');
}

const cursorFile = resolve('assets/cursor.svg');
const cameraTrack = buildCameraTrack(
  timeline.events,
  planManifest.outputDurationMs,
  captureManifest.viewport,
);
const cursorTrack = buildCursorTrack(timeline.events, captureManifest.viewport);
const feedbackTrack = buildClickFeedbackTrack(timeline.events);
const createCompositor = async () =>
  new StudioFrameCompositor(
    planManifest.sourcePixelWidth,
    planManifest.sourcePixelHeight,
    captureManifest.viewport,
    await loadCursorAsset(cursorFile),
    new SequentialCameraEvaluator(cameraTrack),
    new SequentialCursorEvaluator(cursorTrack),
    new SequentialClickFeedbackEvaluator(feedbackTrack),
  );
const createLoader = () =>
  SequentialSourceImageLoader.create(
    captureDirectory,
    planManifest.sourcePixelWidth,
    planManifest.sourcePixelHeight,
  );

await verifyFailureCleanup(ffmpeg, outputDirectory);
const outputPath = resolve(outputDirectory, 'soredemo-day8.mp4');
let validation: Awaited<ReturnType<typeof validateEncodedVideo>> | undefined;
const encoder = await FfmpegEncoder.create({
  executable: ffmpeg,
  config: encodingConfig(outputPath, planManifest.outputFrameCount),
  logPath: resolve(outputDirectory, 'ffmpeg.log'),
  validateTemporary: async (file) => {
    validation = await validateEncodedVideo({
      file,
      ffprobe,
      ffmpeg,
      width: OUTPUT_WIDTH,
      height: OUTPUT_HEIGHT,
      fps: OUTPUT_FPS,
      frameCount: planManifest.outputFrameCount,
    });
  },
});

const parentRssBeforeBytes = process.memoryUsage().rss;
const parentRssSamples = [parentRssBeforeBytes];
let ffmpegPeakRssBytes = 0;
let rssSampling = false;
const rssTimer = setInterval(() => {
  parentRssSamples.push(process.memoryUsage().rss);
  if (!rssSampling && encoder.childPid) {
    rssSampling = true;
    sampleChildRss(encoder.childPid)
      .then((bytes) => {
        ffmpegPeakRssBytes = Math.max(ffmpegPeakRssBytes, bytes);
      })
      .catch(() => {})
      .finally(() => {
        rssSampling = false;
      });
  }
}, 500);
const compositionStartedAt = performance.now();
let compositionRun: Awaited<ReturnType<typeof runComposition>>;
let encoded: Awaited<ReturnType<typeof encoder.finalize>>;
try {
  compositionRun = await runComposition({
    frames: selectedFrames(records),
    sourceWidth: planManifest.sourcePixelWidth,
    sourceHeight: planManifest.sourcePixelHeight,
    loader: await createLoader(),
    compositor: await createCompositor(),
    consumer: encoder,
  });
  encoded = await encoder.finalize();
} catch (error) {
  await encoder.abort(error);
  throw error;
} finally {
  clearInterval(rssTimer);
}
const compositionAndEncodingMs = performance.now() - compositionStartedAt;
const parentRssAfterBytes = process.memoryUsage().rss;
parentRssSamples.push(parentRssAfterBytes);
if (!validation) throw new Error('Successful encoder finalization did not run MP4 validation');
const validated = validation as Awaited<ReturnType<typeof validateEncodedVideo>>;

await writeFile(
  resolve(outputDirectory, 'ffprobe.json'),
  `${JSON.stringify(validated.ffprobeJson, null, 2)}\n`,
);
await writeFile(
  resolve(outputDirectory, 'frame-timing.jsonl'),
  `${validated.video.frames.map((frame) => JSON.stringify(frame)).join('\n')}\n`,
);

const fidelityIndices = uniqueSorted([0, 26, 34, 60, 119, 808, planManifest.outputFrameCount - 1]);
const originalFrames = await composeSelected(fidelityIndices);
const decodedFrames = await decodeSelectedFrames(ffmpeg, outputPath, fidelityIndices);
const fidelity = [];
for (const index of fidelityIndices) {
  const original = originalFrames.get(index);
  const decoded = decodedFrames.get(index);
  if (!original || !decoded) throw new Error(`Missing fidelity frame ${index}`);
  const measurement = measureRgbaFidelity(original, decoded);
  const originalFile = `fidelity/frame-${String(index).padStart(6, '0')}-original.png`;
  const decodedFile = `fidelity/frame-${String(index).padStart(6, '0')}-decoded.png`;
  await writeFile(resolve(outputDirectory, originalFile), pngFromRgba(original));
  await writeFile(resolve(outputDirectory, decodedFile), pngFromRgba(decoded));
  fidelity.push({ outputIndex: index, ...measurement, originalFile, decodedFile });
}

const repeatability = await runRepeatability(records.slice(55, 76));
const ffmpegWarnings = (await readFile(resolve(outputDirectory, 'ffmpeg.log'), 'utf8'))
  .split(/\r?\n/)
  .filter(Boolean);
const manifest = {
  schemaVersion: 1,
  input: {
    outputWidth: OUTPUT_WIDTH,
    outputHeight: OUTPUT_HEIGHT,
    fps: OUTPUT_FPS,
    frameCount: planManifest.outputFrameCount,
    pixelFormat: 'rgba',
    rgbaBytesPerFrame: RGBA_BYTE_LENGTH,
    totalLogicalRgbaBytes: compositionRun.bytesProcessed,
    studioCompositionSha256: day8Manifest.rollingRgbaSha256,
  },
  encoder: {
    provider: 'system-ffmpeg',
    executablePath: ffmpeg.resolvedPath,
    executableRealPath: ffmpeg.realPath,
    executableSha256: capabilities.executableSha256,
    ffprobePath: ffprobe.resolvedPath,
    ffprobeRealPath: ffprobe.realPath,
    ffmpegVersion: capabilities.ffmpegVersion,
    ffprobeVersion: capabilities.ffprobeVersion,
    compilerLine: capabilities.compilerLine,
    configureArguments: capabilities.configureArguments,
    codec: 'libx264',
    preset: 'medium',
    crf: 18,
    outputPixelFormat: 'yuv420p',
    gplEnabled: capabilities.gplEnabled,
    libx264Enabled: capabilities.libx264Enabled,
    libx264EncoderPresent: capabilities.libx264EncoderPresent,
    rawvideoInputPresent: capabilities.rawvideoInputPresent,
  },
  output: {
    file: 'soredemo-day8.mp4',
    byteLength: encoded.byteLength,
    sha256: encoded.sha256,
    codecName: validated.video.codecName,
    profile: validated.video.profile,
    level: validated.video.level,
    pixelFormat: validated.video.pixelFormat,
    width: validated.video.width,
    height: validated.video.height,
    fps: validated.video.averageFrameRate,
    frameCount: validated.video.frameCount,
    finalFrameTimestampSeconds: (validated.video.frameCount - 1) / OUTPUT_FPS,
    durationSeconds: validated.video.durationSeconds,
    bitRate: validated.video.bitRate,
    audioStreams: validated.video.audioStreams,
    colorPrimaries: validated.video.colorPrimaries,
    colorTransfer: validated.video.colorTransfer,
    colorSpace: validated.video.colorSpace,
    colorRange: validated.video.colorRange,
    fastStart: validated.video.fastStart,
  },
  backpressure: encoded.backpressure,
  process: {
    ffmpegExitCode: encoded.ffmpegExitCode,
    ffmpegSignal: encoded.ffmpegSignal,
    warnings: ffmpegWarnings,
  },
  fidelity,
  repeatability,
  failureCleanup: { passed: true, previousOutputPreserved: true, partialFilesRemaining: 0 },
  performance: {
    compositionAndEncodingMs,
    effectiveFramesPerSecond: planManifest.outputFrameCount / (compositionAndEncodingMs / 1000),
    parentRssBeforeBytes,
    parentPeakRssBytes: Math.max(...parentRssSamples),
    parentRssAfterBytes,
    ffmpegPeakRssBytes,
    approximateCombinedPeakBytes: Math.max(...parentRssSamples) + ffmpegPeakRssBytes,
  },
};
await writeFile(
  resolve(outputDirectory, 'manifest.json'),
  `${JSON.stringify(manifest, null, 2)}\n`,
);

const passed =
  compositionRun.framesProcessed === planManifest.outputFrameCount &&
  encoded.backpressure.framesWritten === planManifest.outputFrameCount &&
  encoded.backpressure.maxPendingFrames <= 1 &&
  validated.video.frameCount === planManifest.outputFrameCount &&
  validated.video.fastStart &&
  Math.max(...parentRssSamples) < 1024 ** 3 &&
  repeatability.decodedFramesIdentical &&
  repeatability.metadataIdentical;
process.stderr.write(
  [
    'Day 9 FFmpeg encoding',
    `frames       ${compositionRun.framesProcessed} composed / ${encoded.backpressure.framesWritten} written`,
    `output       ${(encoded.byteLength / 1024 ** 2).toFixed(2)} MiB ${validated.video.profile} level ${validated.video.level}`,
    `timing       ${validated.video.frameCount} frames / ${validated.video.durationSeconds.toFixed(6)} s / ${validated.video.averageFrameRate} fps`,
    `backpressure ${encoded.backpressure.writeFalseCount} write-false / ${encoded.backpressure.drainCount} drain / ${encoded.backpressure.maxPendingFrames} pending`,
    `memory       ${(Math.max(...parentRssSamples) / 1024 ** 2).toFixed(1)} MiB parent / ${(ffmpegPeakRssBytes / 1024 ** 2).toFixed(1)} MiB FFmpeg`,
    `result       ${passed ? 'PASS' : 'FAIL'}`,
    '',
  ].join('\n'),
);
process.stdout.write(`${JSON.stringify({ passed, ...manifest })}\n`);
if (!passed) process.exitCode = 1;

function encodingConfig(outputPath: string, expectedFrameCount: number) {
  return {
    outputPath,
    width: OUTPUT_WIDTH,
    height: OUTPUT_HEIGHT,
    fps: OUTPUT_FPS,
    expectedFrameCount,
    codec: 'libx264' as const,
    pixelFormat: 'yuv420p' as const,
    preset: 'medium' as const,
    crf: 18 as const,
    overwrite: true,
  };
}

async function* selectedFrames(
  source: readonly ResampledFrameRecord[],
): AsyncGenerator<ResampledFrameRecord> {
  for (const record of source) yield record;
}

function uniqueSorted(values: readonly number[]): number[] {
  return [...new Set(values)].sort((left, right) => left - right);
}

async function sampleChildRss(pid: number): Promise<number> {
  const result = await runCapturedProcess({
    executable: '/bin/ps',
    arguments: ['-o', 'rss=', '-p', String(pid)],
    maxOutputBytes: 4096,
    timeoutMs: 2_000,
  });
  if (result.exitCode !== 0) return 0;
  const kibibytes = Number(result.stdout.toString('utf8').trim());
  return Number.isFinite(kibibytes) ? kibibytes * 1024 : 0;
}

async function verifyFailureCleanup(executable: ResolvedExecutable, directory: string) {
  const output = resolve(directory, 'failure-preserved.mp4');
  const log = resolve(directory, 'failure-ffmpeg.log');
  await writeFile(output, 'previous-valid-output');
  const failureEncoder = await FfmpegEncoder.create({
    executable,
    config: encodingConfig(output, 2),
    logPath: log,
    validateTemporary: async () => {},
  });
  let failed = false;
  try {
    await failureEncoder.finalize();
  } catch {
    failed = true;
  }
  if (!failed || (await readFile(output, 'utf8')) !== 'previous-valid-output') {
    throw new Error('Atomic failure cleanup did not preserve the prior output');
  }
  const partials = (await readdir(directory)).filter((file) => file.includes('.partial.mp4'));
  if (partials.length > 0) throw new Error('Atomic failure cleanup left a partial MP4');
  await Promise.all([unlink(output), unlink(log)]);
}

async function composeSelected(indices: readonly number[]): Promise<Map<number, Uint8Array>> {
  const selected = records.filter((record) => indices.includes(record.outputIndex));
  const output = new Map<number, Uint8Array>();
  const consumer: FrameConsumer = {
    async consume(frame) {
      output.set(frame.outputIndex, Uint8Array.from(frame.data));
    },
  };
  await runComposition({
    frames: selectedFrames(selected),
    sourceWidth: planManifest.sourcePixelWidth,
    sourceHeight: planManifest.sourcePixelHeight,
    loader: await createLoader(),
    compositor: await createCompositor(),
    consumer,
    requireConsecutiveOutputIndices: false,
  });
  return output;
}

async function decodeSelectedFrames(
  executable: ResolvedExecutable,
  file: string,
  indices: readonly number[],
): Promise<Map<number, Uint8Array>> {
  const expression = indices.map((index) => `eq(n\\,${index})`).join('+');
  const result = requireSuccessfulProcess(
    await runCapturedProcess({
      executable: executable.resolvedPath,
      arguments: [
        '-hide_banner',
        '-v',
        'error',
        '-i',
        file,
        '-vf',
        `select=${expression}`,
        '-fps_mode',
        'passthrough',
        '-f',
        'rawvideo',
        '-pix_fmt',
        'rgba',
        'pipe:1',
      ],
      maxOutputBytes: indices.length * RGBA_BYTE_LENGTH + 1024,
      timeoutMs: 180_000,
    }),
    'Selected-frame decode',
  );
  if (result.stdout.byteLength !== indices.length * RGBA_BYTE_LENGTH) {
    throw new Error('Selected-frame decode returned the wrong RGBA byte count');
  }
  const output = new Map<number, Uint8Array>();
  indices.forEach((index, position) => {
    const start = position * RGBA_BYTE_LENGTH;
    output.set(index, Uint8Array.from(result.stdout.subarray(start, start + RGBA_BYTE_LENGTH)));
  });
  return output;
}

function pngFromRgba(data: Uint8Array): Buffer {
  const canvas = createCanvas(OUTPUT_WIDTH, OUTPUT_HEIGHT);
  canvas
    .getContext('2d')
    .putImageData(new ImageData(new Uint8ClampedArray(data), OUTPUT_WIDTH, OUTPUT_HEIGHT), 0, 0);
  return canvas.toBuffer('image/png');
}

async function runRepeatability(subset: readonly ResampledFrameRecord[]) {
  const results = [];
  for (const run of [1, 2]) {
    const file = resolve(outputDirectory, `repeat-${run}.mp4`);
    const log = resolve(outputDirectory, `repeat-${run}.log`);
    let validationResult: Awaited<ReturnType<typeof validateEncodedVideo>> | undefined;
    const repeatEncoder = await FfmpegEncoder.create({
      executable: ffmpeg,
      config: encodingConfig(file, subset.length),
      logPath: log,
      validateTemporary: async (temporary) => {
        validationResult = await validateEncodedVideo({
          file: temporary,
          ffprobe,
          ffmpeg,
          width: OUTPUT_WIDTH,
          height: OUTPUT_HEIGHT,
          fps: OUTPUT_FPS,
          frameCount: subset.length,
        });
      },
    });
    let localIndex = 0;
    const remappingConsumer: FrameConsumer = {
      async consume(frame: RawRgbaFrame) {
        await repeatEncoder.consume({
          ...frame,
          outputIndex: localIndex,
          outputTimestampMs: (localIndex * 1000) / OUTPUT_FPS,
        });
        localIndex += 1;
      },
    };
    try {
      await runComposition({
        frames: selectedFrames(subset),
        sourceWidth: planManifest.sourcePixelWidth,
        sourceHeight: planManifest.sourcePixelHeight,
        loader: await createLoader(),
        compositor: await createCompositor(),
        consumer: remappingConsumer,
        requireConsecutiveOutputIndices: false,
      });
      const encodedSubset = await repeatEncoder.finalize();
      if (!validationResult) throw new Error('Repeat encode did not validate');
      const decoded = await decodeSelectedFrames(ffmpeg, file, [0, 5, subset.length - 1]);
      const decodedHashes = [...decoded.values()].map((frame) =>
        createHash('sha256').update(frame).digest('hex'),
      );
      results.push({
        mp4Sha256: encodedSubset.sha256,
        byteLength: encodedSubset.byteLength,
        video: (validationResult as { video: ValidatedVideo }).video,
        decodedHashes,
      });
    } catch (error) {
      await repeatEncoder.abort(error);
      throw error;
    } finally {
      await Promise.all([unlink(file).catch(() => {}), unlink(log).catch(() => {})]);
    }
  }
  const first = results[0];
  const second = results[1];
  if (!first || !second) throw new Error('Repeatability runs did not complete');
  return {
    frameCount: subset.length,
    firstMp4Sha256: first.mp4Sha256,
    secondMp4Sha256: second.mp4Sha256,
    bitIdentical: first.mp4Sha256 === second.mp4Sha256,
    metadataIdentical: JSON.stringify(first.video) === JSON.stringify(second.video),
    decodedFramesIdentical:
      JSON.stringify(first.decodedHashes) === JSON.stringify(second.decodedHashes),
    decodedFrameHashes: first.decodedHashes,
  };
}
