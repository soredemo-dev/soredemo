import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { executeActions } from '../capture/action-executor.js';
import { captureSession } from '../capture/capture-session.js';
import {
  hideBrowserCursor,
  installPageInstrumentation,
  verifyPageInstrumentation,
} from '../capture/page-instrumentation.js';
import { writeTimeline } from '../capture/timeline-writer.js';
import { SequentialCameraEvaluator } from '../compositor/camera-evaluator.js';
import { projectCssPoint } from '../compositor/camera-projection.js';
import { measureTargetFraming } from '../compositor/camera-statistics.js';
import { buildCameraTrack } from '../compositor/camera-track.js';
import {
  buildClickFeedbackTrack,
  SequentialClickFeedbackEvaluator,
} from '../compositor/click-feedback-track.js';
import { openCompositionPlan } from '../compositor/composition-plan-reader.js';
import { loadCursorAsset } from '../compositor/cursor-asset.js';
import { SequentialCursorEvaluator } from '../compositor/cursor-track.js';
import { runComposition } from '../compositor/frame-runner.js';
import { cursorLandingStatistics, measureCursorLanding } from '../compositor/landing-statistics.js';
import { SequentialSourceImageLoader } from '../compositor/source-image-loader.js';
import { StudioFrameCompositor } from '../compositor/studio-frame-compositor.js';
import { STUDIO_BROWSER_CONTENT_RECT } from '../compositor/studio-layout.js';
import { OUTPUT_FPS, OUTPUT_HEIGHT, OUTPUT_WIDTH } from '../compositor/types.js';
import type { ProjectConfiguration } from '../config/load.js';
import { resolveExecutable, resolveFfprobe } from '../encoder/executable-resolver.js';
import { FfmpegEncoder } from '../encoder/ffmpeg-encoder.js';
import { inspectFfmpeg } from '../encoder/ffmpeg-preflight.js';
import { validateEncodedVideo } from '../encoder/ffprobe-validation.js';
import type {
  EncodedVideoResult,
  FfmpegCapabilities,
  ResolvedExecutable,
  ValidatedVideo,
} from '../encoder/types.js';
import type { ActionPlan } from '../plan/normalized-plan.js';
import { nearestOutputIndex } from '../resample/event-frame-mapping.js';
import type { ResampledFrameRecord } from '../resample/types.js';
import { buildCursorTrack } from '../timeline/cursor-track-validation.js';
import type { TimelineDocument } from '../timeline/types.js';
import { resampleCapture } from './resample-capture.js';
import { RenderWorkspace } from './workspace.js';

const execFileAsync = promisify(execFile);

export interface RenderDemoOptions {
  plan: ActionPlan;
  planFile: string;
  configuration: ProjectConfiguration;
  outputPath: string;
  keepArtifacts: boolean;
  onStage?: (message: string) => void;
}

export interface RenderDemoResult {
  success: true;
  outputPath: string;
  outputBytes: number;
  outputSha256: string;
  durationSeconds: number;
  frameCount: number;
  fps: number;
  renderDurationMs: number;
  preservedArtifactsPath?: string;
  diagnostics: {
    actionCount: number;
    captureFrameCount: number;
    captureDurationMs: number;
    captureDimensions: { width: number; height: number };
    cursorPathCount: number;
    cursorPointCount: number;
    cameraSegmentCount: number;
    rippleCount: number;
    landingMedianPx: number;
    landingP95Px: number;
    fullyVisibleTargets: number;
    encoder: EncodedVideoResult['backpressure'];
    parentRssPeakBytes: number;
    ffmpegRssPeakBytes?: number;
  };
}

export class RenderPipelineError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly workspacePath: string,
    options?: ErrorOptions,
  ) {
    super(message, options);
    this.name = 'RenderPipelineError';
  }
}

function stage(options: RenderDemoOptions, message: string): void {
  options.onStage?.(message);
}

function assertProductionGeometry(options: RenderDemoOptions): void {
  const viewport = options.configuration.viewport ?? options.plan.viewport;
  if (viewport.width !== 1440 || viewport.height !== 900) {
    throw new Error('CONFIG_INVALID: v0.1 capture viewport must be 1440x900');
  }
  if (options.configuration.deviceScaleFactor !== 2) {
    throw new Error('CONFIG_INVALID: v0.1 device scale factor must be 2');
  }
}

function failureCode(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  const known = [
    'CONFIG_INVALID',
    'TARGET_NOT_FOUND',
    'TARGET_AMBIGUOUS',
    'ACTION_TIMEOUT',
    'NAVIGATION_FAILED',
    'CAPTURE_FAILED',
    'FFMPEG_NOT_FOUND',
    'ENCODER_CAPABILITY_MISSING',
    'ENCODE_FAILED',
    'OUTPUT_VALIDATION_FAILED',
    'RENDER_ABORTED',
  ];
  return known.find((code) => message.includes(code)) ?? 'RENDER_FAILED';
}

async function sampleChildRss(pid: number): Promise<number> {
  if (process.platform !== 'darwin') return 0;
  const { stdout } = await execFileAsync('/bin/ps', ['-o', 'rss=', '-p', String(pid)]);
  const kibibytes = Number(stdout.trim());
  return Number.isFinite(kibibytes) ? kibibytes * 1024 : 0;
}

export async function renderDemo(options: RenderDemoOptions): Promise<RenderDemoResult> {
  const startedAt = performance.now();
  assertProductionGeometry(options);
  const workspace = await RenderWorkspace.create({
    root: options.configuration.runsDirectory,
    planFile: options.planFile,
    ...(options.configuration.file ? { configFile: options.configuration.file } : {}),
    output: options.outputPath,
    actionCount: options.plan.actions.length,
  });
  const abortController = new AbortController();
  const abort = () => abortController.abort(new Error('RENDER_ABORTED: Render was interrupted'));
  process.once('SIGINT', abort);
  process.once('SIGTERM', abort);
  let completedActions = 0;
  let encoder: FfmpegEncoder | undefined;

  try {
    await workspace.removeOwnedStalePartials();
    stage(options, 'Checking FFmpeg');
    let ffmpeg: ResolvedExecutable;
    let ffprobe: ResolvedExecutable;
    try {
      ffmpeg = await resolveExecutable({
        name: 'ffmpeg',
        environmentVariable: 'SOREDEMO_FFMPEG_PATH',
      });
      ffprobe = await resolveFfprobe(ffmpeg);
    } catch (error) {
      throw new Error(
        `FFMPEG_NOT_FOUND: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    let capabilities: FfmpegCapabilities;
    try {
      capabilities = await inspectFfmpeg(ffmpeg, ffprobe);
    } catch (error) {
      throw new Error(
        `ENCODER_CAPABILITY_MISSING: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    await Promise.all([
      writeFile(`${workspace.encodeDirectory}/ffmpeg-version.txt`, `${capabilities.raw.version}\n`),
      writeFile(
        `${workspace.encodeDirectory}/ffmpeg-buildconf.txt`,
        `${capabilities.raw.buildconf}\n`,
      ),
      writeFile(
        `${workspace.encodeDirectory}/ffmpeg-encoders.txt`,
        `${capabilities.raw.encoders}\n`,
      ),
    ]);

    stage(options, 'Launching Chromium');
    await workspace.update({ status: 'capturing' });
    const source = await readFile(options.planFile);
    let timeline: TimelineDocument | undefined;
    const viewport = options.configuration.viewport ?? options.plan.viewport;
    const capture = await captureSession({
      url: options.plan.initialUrl,
      outputDirectory: workspace.captureDirectory,
      durationMs: Math.max(120_000, options.plan.intent.targetDurationMs ?? 0),
      sourceIdentifier: options.plan.name,
      scriptHash: createHash('sha256').update(source).digest('hex'),
      viewport,
      deviceScaleFactor: options.configuration.deviceScaleFactor,
      initialWaitUntil: 'domcontentloaded',
      readySelector: null,
      navigationTimeoutMs: 30_000,
      settleBeforeCaptureMs: 300,
      tailDurationMs: 1_000,
      beforePageCreation: installPageInstrumentation,
      preparePage: async (page) => {
        await hideBrowserCursor(page);
        await verifyPageInstrumentation(page);
      },
      runDuringCapture: async ({ page, captureOriginEpochMs, startupCalibration }) => {
        await new Promise((resolve) => setTimeout(resolve, 600));
        stage(options, `Capturing ${options.plan.actions.length} actions`);
        timeline = await executeActions(
          {
            page,
            startupCalibration,
            captureOriginEpochMs,
            cursor: { x: 0, y: 0 },
            cssViewport: viewport,
            signal: abortController.signal,
            pace: options.plan.style.pace,
          },
          options.plan.actions,
          async (count) => {
            completedActions = count;
            await workspace.update({ completedActions: count });
          },
        );
      },
    });
    if (!timeline) throw new Error('CAPTURE_FAILED: Action execution produced no timeline');
    await writeTimeline(workspace.captureDirectory, timeline, capture.manifest.captureDurationMs);
    await workspace.update({ captureFrameCount: capture.manifest.frameCount });

    stage(options, 'Resampling captured frames');
    await workspace.update({ status: 'resampling' });
    const resample = await resampleCapture(workspace.captureDirectory, workspace.resampleDirectory);
    await workspace.update({ outputFrameCount: resample.outputFrameCount });

    stage(options, 'Rendering and encoding');
    await workspace.update({ status: 'composing' });
    const cameraTrack = buildCameraTrack(timeline.events, resample.outputDurationMs, viewport);
    const cursorTrack = buildCursorTrack(timeline.events, viewport);
    const feedbackTrack = buildClickFeedbackTrack(timeline.events);
    const clicks = timeline.events.filter((event) => event.kind === 'click');
    const clickIndices = new Set(
      clicks.map((click) => nearestOutputIndex(click.mouseDownMs, resample.outputFrameCount)),
    );
    const selectedClickFrames = new Map<number, ResampledFrameRecord>();
    const diagnosticReader = await openCompositionPlan(workspace.resampleDirectory);
    for await (const record of diagnosticReader.frames()) {
      if (clickIndices.has(record.outputIndex)) selectedClickFrames.set(record.outputIndex, record);
    }
    const diagnosticCamera = new SequentialCameraEvaluator(cameraTrack);
    const diagnosticCursor = new SequentialCursorEvaluator(cursorTrack);
    const landingMeasurements = [];
    const framingMeasurements = [];
    for (const click of clicks) {
      const outputIndex = nearestOutputIndex(click.mouseDownMs, resample.outputFrameCount);
      const record = selectedClickFrames.get(outputIndex);
      if (!record) throw new Error(`OUTPUT_VALIDATION_FAILED: Missing click frame ${outputIndex}`);
      const camera = diagnosticCamera.evaluate(record.outputTimestampMs);
      const cursor = diagnosticCursor.evaluate(record.outputTimestampMs);
      if (!cursor.visible || cursor.cssX === undefined || cursor.cssY === undefined) {
        throw new Error(`OUTPUT_VALIDATION_FAILED: ${click.id} has no cursor at mouse down`);
      }
      const cursorScreen = projectCssPoint(
        { x: cursor.cssX, y: cursor.cssY },
        camera,
        viewport,
        STUDIO_BROWSER_CONTENT_RECT,
      );
      const clickScreen = projectCssPoint(
        click.clickPoint,
        camera,
        viewport,
        STUDIO_BROWSER_CONTENT_RECT,
      );
      landingMeasurements.push(
        measureCursorLanding({ click, outputFrame: record, cursor, cursorScreen, clickScreen }),
      );
      framingMeasurements.push(
        measureTargetFraming({
          click,
          outputIndex,
          camera,
          viewport,
          contentRect: STUDIO_BROWSER_CONTENT_RECT,
        }),
      );
    }
    const landing = clicks.length > 0 ? cursorLandingStatistics(landingMeasurements) : undefined;
    if (landing && (landing.distanceOutputPx.median > 1 || landing.distanceOutputPx.p95 > 2)) {
      throw new Error('OUTPUT_VALIDATION_FAILED: Cursor landing gate failed');
    }
    if (
      framingMeasurements.some(
        (measurement) =>
          Math.abs(measurement.visibleFraction - 1) > 1e-7 ||
          !measurement.clickPointInsideProjectedTarget,
      )
    ) {
      throw new Error('OUTPUT_VALIDATION_FAILED: Target framing gate failed');
    }
    await Promise.all([
      writeFile(
        `${workspace.directory}/landing-measurements.json`,
        `${JSON.stringify({ measurements: landingMeasurements, statistics: landing }, null, 2)}\n`,
      ),
      writeFile(
        `${workspace.directory}/target-framing.json`,
        `${JSON.stringify(framingMeasurements, null, 2)}\n`,
      ),
    ]);
    const planReader = await openCompositionPlan(workspace.resampleDirectory);
    const compositor = new StudioFrameCompositor(
      resample.sourcePixelWidth,
      resample.sourcePixelHeight,
      viewport,
      await loadCursorAsset(fileURLToPath(new URL('../../assets/cursor.svg', import.meta.url))),
      new SequentialCameraEvaluator(cameraTrack),
      new SequentialCursorEvaluator(cursorTrack),
      new SequentialClickFeedbackEvaluator(feedbackTrack),
    );
    const loader = await SequentialSourceImageLoader.create(
      workspace.captureDirectory,
      resample.sourcePixelWidth,
      resample.sourcePixelHeight,
    );
    let validated: Awaited<ReturnType<typeof validateEncodedVideo>> | undefined;
    encoder = await FfmpegEncoder.create({
      executable: ffmpeg,
      config: {
        outputPath: options.outputPath,
        width: OUTPUT_WIDTH,
        height: OUTPUT_HEIGHT,
        fps: OUTPUT_FPS,
        expectedFrameCount: resample.outputFrameCount,
        codec: 'libx264',
        pixelFormat: 'yuv420p',
        preset: 'medium',
        crf: 18,
        overwrite: false,
      },
      logPath: `${workspace.encodeDirectory}/ffmpeg.log`,
      validateTemporary: async (file) => {
        await workspace.update({ status: 'validating' });
        validated = await validateEncodedVideo({
          file,
          ffprobe,
          ffmpeg,
          width: OUTPUT_WIDTH,
          height: OUTPUT_HEIGHT,
          fps: OUTPUT_FPS,
          frameCount: resample.outputFrameCount,
        });
        await writeFile(
          `${workspace.encodeDirectory}/ffprobe.json`,
          `${JSON.stringify(validated.ffprobeJson, null, 2)}\n`,
        );
      },
    });
    await workspace.update({ status: 'encoding' });
    const rssSamples = [process.memoryUsage().rss];
    let ffmpegRssPeakBytes = 0;
    let sampling = false;
    const rssTimer = setInterval(() => {
      rssSamples.push(process.memoryUsage().rss);
      if (!sampling && encoder?.childPid) {
        sampling = true;
        sampleChildRss(encoder.childPid)
          .then((bytes) => {
            ffmpegRssPeakBytes = Math.max(ffmpegRssPeakBytes, bytes);
          })
          .catch(() => undefined)
          .finally(() => {
            sampling = false;
          });
      }
    }, 500);
    let encoded: EncodedVideoResult;
    try {
      await runComposition({
        frames: planReader.frames(),
        sourceWidth: resample.sourcePixelWidth,
        sourceHeight: resample.sourcePixelHeight,
        loader,
        compositor,
        consumer: encoder,
      });
      encoded = await encoder.finalize();
    } catch (error) {
      await encoder.abort(error);
      throw new Error(`ENCODE_FAILED: ${error instanceof Error ? error.message : String(error)}`, {
        cause: error,
      });
    } finally {
      clearInterval(rssTimer);
    }
    rssSamples.push(process.memoryUsage().rss);
    if (!validated) throw new Error('OUTPUT_VALIDATION_FAILED: No validated video result');
    const video = (validated as { video: ValidatedVideo }).video;
    await writeFile(
      `${workspace.encodeDirectory}/manifest.json`,
      `${JSON.stringify(
        {
          schemaVersion: 1,
          output: encoded,
          video,
          ffmpeg: {
            executable: ffmpeg.realPath,
            version: capabilities.ffmpegVersion,
            gplEnabled: capabilities.gplEnabled,
            libx264Enabled: capabilities.libx264Enabled,
          },
        },
        null,
        2,
      )}\n`,
    );
    await workspace.update({ status: 'completed', completedAt: new Date().toISOString() });
    const renderDurationMs = performance.now() - startedAt;
    const cursorEvents = timeline.events.filter(
      (event) => event.kind === 'moveTo' || event.kind === 'click' || event.kind === 'type',
    );
    const result: RenderDemoResult = {
      success: true,
      outputPath: encoded.outputPath,
      outputBytes: encoded.byteLength,
      outputSha256: encoded.sha256,
      durationSeconds: video.durationSeconds,
      frameCount: encoded.frameCount,
      fps: OUTPUT_FPS,
      renderDurationMs,
      ...(options.keepArtifacts ? { preservedArtifactsPath: workspace.directory } : {}),
      diagnostics: {
        actionCount: timeline.events.length,
        captureFrameCount: capture.manifest.frameCount,
        captureDurationMs: capture.manifest.captureDurationMs,
        captureDimensions: {
          width: capture.manifest.expectedFrameDimensions.pixelWidth,
          height: capture.manifest.expectedFrameDimensions.pixelHeight,
        },
        cursorPathCount: cursorEvents.length,
        cursorPointCount: cursorTrack.pointCount,
        cameraSegmentCount: cameraTrack.segments.length,
        rippleCount: feedbackTrack.clicks.length,
        landingMedianPx: landing?.distanceOutputPx.median ?? 0,
        landingP95Px: landing?.distanceOutputPx.p95 ?? 0,
        fullyVisibleTargets: framingMeasurements.filter(
          (measurement) => Math.abs(measurement.visibleFraction - 1) <= 1e-7,
        ).length,
        encoder: encoded.backpressure,
        parentRssPeakBytes: Math.max(...rssSamples),
        ...(ffmpegRssPeakBytes > 0 ? { ffmpegRssPeakBytes } : {}),
      },
    };
    if (!options.keepArtifacts) await workspace.cleanup();
    return result;
  } catch (error) {
    await encoder?.abort(error).catch(() => undefined);
    const code = failureCode(error);
    const message = error instanceof Error ? error.message : String(error);
    await workspace
      .update({
        status: abortController.signal.aborted ? 'aborted' : 'failed',
        completedAt: new Date().toISOString(),
        completedActions,
        failure: { code, message },
      })
      .catch(() => undefined);
    throw new RenderPipelineError(code, message, workspace.directory, { cause: error });
  } finally {
    process.off('SIGINT', abort);
    process.off('SIGTERM', abort);
  }
}
