import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readdir, readFile, writeFile } from 'node:fs/promises';
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
import {
  cursorActionFrameRequests,
  isCursorBearingEvent,
} from '../compositor/cursor-action-landing.js';
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
import { CursorActionAuditConsumer, type CursorActionAuditResult } from './cursor-action-audit.js';
import {
  normalizeRenderError,
  RenderError,
  type RenderStage,
  type RenderWarning,
} from './errors.js';
import { type DecodedCursorProofRecord, decodeCursorProofFrames } from './mp4-cursor-proof.js';
import { resampleCapture } from './resample-capture.js';
import { RenderWorkspace } from './workspace.js';

const execFileAsync = promisify(execFile);

export interface RenderDemoOptions {
  plan: ActionPlan;
  planFile: string;
  configuration: ProjectConfiguration;
  outputPath: string;
  keepArtifacts: boolean;
  validationStartedAt?: string;
  onStage?: (event: {
    stage: RenderStage;
    status: 'completed';
    message: string;
    details?: Record<string, unknown>;
  }) => void;
  onDiagnostic?: (message: string, details?: Record<string, unknown>) => void;
}

export interface RenderDemoResult {
  success: true;
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
  warnings: RenderWarning[];
  artifactsPath?: string;
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
    cursorActionLandings: { moveTo: number; click: number; type: number };
    cursorActionFailures: number;
    rgbaRollingSha256: string;
    decodedCursorProofs: number;
    fullyVisibleTargets: number;
    encoder: EncodedVideoResult['backpressure'];
    parentRssPeakBytes: number;
    ffmpegRssPeakBytes?: number;
  };
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

async function sampleChildRss(pid: number): Promise<number> {
  if (process.platform !== 'darwin') return 0;
  const { stdout } = await execFileAsync('/bin/ps', ['-o', 'rss=', '-p', String(pid)]);
  const kibibytes = Number(stdout.trim());
  return Number.isFinite(kibibytes) ? kibibytes * 1024 : 0;
}

async function beginStage(workspace: RenderWorkspace, stage: RenderStage): Promise<void> {
  await workspace.startStage(stage);
}

async function completeStage(
  workspace: RenderWorkspace,
  options: RenderDemoOptions,
  stage: RenderStage,
  message: string,
  details?: Record<string, unknown>,
): Promise<void> {
  await workspace.finishStage(stage);
  options.onStage?.({ stage, status: 'completed', message, ...(details ? { details } : {}) });
}

export function assertCursorSynchronization(
  result: Pick<CursorActionAuditResult, 'statistics'>,
  expectedCount: number,
): void {
  if (result.statistics.total === expectedCount && result.statistics.failures === 0) return;
  throw new RenderError({
    code: 'CURSOR_SYNCHRONIZATION_FAILED',
    stage: 'composing',
    message: 'Cursor-bearing action landing gate failed',
    details: { expectedCount, statistics: result.statistics },
  });
}

async function readJsonIfPresent(file: string): Promise<Record<string, unknown> | undefined> {
  try {
    return JSON.parse(await readFile(file, 'utf8')) as Record<string, unknown>;
  } catch {
    return undefined;
  }
}

async function writeFailureDiagnostics(
  workspace: RenderWorkspace,
  error: RenderError,
  completedActions: number,
  totalActions: number,
): Promise<void> {
  const [captureManifest, captureProof, compositionManifest, diagnosticFiles, framesJsonl] =
    await Promise.all([
      readJsonIfPresent(`${workspace.captureDirectory}/manifest.json`),
      readJsonIfPresent(`${workspace.captureDirectory}/pixel-scale-proof.json`),
      readJsonIfPresent(`${workspace.compositionDirectory}/manifest.json`),
      readdir(workspace.diagnosticsDirectory).catch(() => []),
      readFile(`${workspace.captureDirectory}/frames.jsonl`, 'utf8').catch(() => ''),
    ]);
  const acceptedCaptureFrames = framesJsonl.trim() ? framesJsonl.trim().split('\n').length : 0;
  await writeFile(
    `${workspace.diagnosticsDirectory}/error.json`,
    `${JSON.stringify(
      {
        schemaVersion: 1,
        error: {
          code: error.code,
          message: error.message,
          stage: error.stage,
          ...(error.actionIndex === undefined ? {} : { actionIndex: error.actionIndex }),
          ...(error.actionKind === undefined ? {} : { actionKind: error.actionKind }),
          ...(error.targetDescription === undefined
            ? {}
            : { targetDescription: error.targetDescription }),
          ...(error.details === undefined ? {} : { details: error.details }),
        },
        environment: {
          nodeVersion: process.version,
          platform: process.platform,
          architecture: process.arch,
        },
        completedActions,
        totalActions,
        captureFrameCount: captureManifest?.frameCount ?? acceptedCaptureFrames,
        outputFrameCount: compositionManifest?.frameCount ?? 0,
        capturePixelScaleProof:
          captureManifest?.pixelScaleProof ??
          captureProof ??
          (error.code === 'CAPTURE_PIXEL_SCALE_INVALID' ? (error.details ?? null) : null),
        cursorSynchronization: compositionManifest?.cursorActionLandings ?? null,
        workspacePath: workspace.directory,
        diagnosticFiles: ['error.json', ...diagnosticFiles].slice(0, 20),
      },
      null,
      2,
    )}\n`,
  );
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
  let encoder: FfmpegEncoder | undefined;
  const abort = () => {
    const reason = new Error('RENDER_ABORTED: Render was interrupted');
    abortController.abort(reason);
    void encoder?.abort(reason);
  };
  process.once('SIGINT', abort);
  process.once('SIGTERM', abort);
  let completedActions = 0;
  let failureScreenshotCaptured = false;

  try {
    await workspace.startStage('validating', options.validationStartedAt);
    await completeStage(workspace, options, 'validating', 'Validated demo plan');
    await workspace.removeOwnedStalePartials();
    await beginStage(workspace, 'preflight');
    let ffmpeg: ResolvedExecutable;
    let ffprobe: ResolvedExecutable;
    try {
      ffmpeg = await resolveExecutable({
        name: 'ffmpeg',
        environmentVariable: 'SOREDEMO_FFMPEG_PATH',
      });
      try {
        ffprobe = await resolveFfprobe(ffmpeg);
      } catch (error) {
        throw new RenderError({
          code: 'FFPROBE_NOT_FOUND',
          stage: 'preflight',
          message: error instanceof Error ? error.message : String(error),
          cause: error,
        });
      }
    } catch (error) {
      if (error instanceof RenderError) throw error;
      throw new RenderError({
        code: 'FFMPEG_NOT_FOUND',
        stage: 'preflight',
        message: error instanceof Error ? error.message : String(error),
        cause: error,
      });
    }
    let capabilities: FfmpegCapabilities;
    try {
      capabilities = await inspectFfmpeg(ffmpeg, ffprobe);
    } catch (error) {
      throw new RenderError({
        code: 'ENCODER_CAPABILITY_MISSING',
        stage: 'preflight',
        message: error instanceof Error ? error.message : String(error),
        cause: error,
      });
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
    await completeStage(
      workspace,
      options,
      'preflight',
      `${capabilities.ffmpegVersion} with libx264`,
      {
        ffmpegPath: ffmpeg.realPath,
        ffprobePath: ffprobe.realPath,
        gplEnabled: capabilities.gplEnabled,
      },
    );

    await beginStage(workspace, 'launching-browser');
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
      onLifecycle: async (event) => {
        if (event === 'browser-launched') {
          await completeStage(workspace, options, 'launching-browser', 'Launched Chromium');
          await beginStage(workspace, 'preparing-page');
        } else if (event === 'page-prepared') {
          await completeStage(
            workspace,
            options,
            'preparing-page',
            'Prepared page and proved genuine 2× capture',
          );
          await beginStage(workspace, 'capturing');
        }
      },
      onPixelScaleProof: async (proof) => {
        await writeFile(
          `${workspace.captureDirectory}/pixel-scale-proof.json`,
          `${JSON.stringify(proof, null, 2)}\n`,
        );
      },
      beforePageCreation: installPageInstrumentation,
      preparePage: async (page) => {
        await hideBrowserCursor(page);
        await verifyPageInstrumentation(page);
      },
      runDuringCapture: async ({ page, captureOriginEpochMs, startupCalibration }) => {
        await new Promise((resolve) => setTimeout(resolve, 600));
        options.onDiagnostic?.('Executing demo actions', {
          actionCount: options.plan.actions.length,
        });
        timeline = await executeActions(
          {
            page,
            startupCalibration,
            captureOriginEpochMs,
            cursor: { x: 0, y: 0 },
            cssViewport: viewport,
            signal: abortController.signal,
            pace: options.plan.style.pace,
            onActionFailure: async (error) => {
              if (failureScreenshotCaptured || page.isClosed()) return;
              failureScreenshotCaptured = true;
              const number = String((error.actionIndex ?? 0) + 1).padStart(3, '0');
              const kind = (error.actionKind ?? 'action').replace(/[^a-zA-Z0-9-]/g, '-');
              await page
                .screenshot({
                  path: `${workspace.diagnosticsDirectory}/action-${number}-${kind}-failure.png`,
                  fullPage: false,
                })
                .catch(() => undefined);
            },
          },
          options.plan.actions,
          async (count) => {
            completedActions = count;
            await workspace.update({ completedActions: count });
          },
        );
      },
    }).catch((error) => {
      if (error instanceof RenderError) throw error;
      throw normalizeRenderError(error, { code: 'CAPTURE_FAILED', stage: 'capturing' });
    });
    if (!timeline) throw new Error('CAPTURE_FAILED: Action execution produced no timeline');
    await writeTimeline(workspace.captureDirectory, timeline, capture.manifest.captureDurationMs);
    await workspace.update({ captureFrameCount: capture.manifest.frameCount });
    await completeStage(
      workspace,
      options,
      'capturing',
      `Captured ${timeline.events.length} actions and ${capture.manifest.frameCount} genuine 2× frames`,
      {
        viewport: capture.manifest.viewport,
        devicePixelRatio: capture.manifest.observedBrowserMetrics.devicePixelRatio,
        jpegDimensions: capture.manifest.expectedFrameDimensions,
        pixelScaleProof: capture.manifest.pixelScaleProof,
        playwrightVersion: capture.manifest.playwrightVersion,
        chromiumVersion: capture.manifest.chromiumVersion,
        chromiumLaunchArguments: capture.manifest.chromiumLaunchArguments,
      },
    );

    await beginStage(workspace, 'resampling');
    await workspace.update({ status: 'resampling' });
    const resample = await resampleCapture(
      workspace.captureDirectory,
      workspace.resampleDirectory,
    ).catch((error) => {
      throw normalizeRenderError(error, { code: 'RESAMPLE_FAILED', stage: 'resampling' });
    });
    await workspace.update({ outputFrameCount: resample.outputFrameCount });
    await completeStage(
      workspace,
      options,
      'resampling',
      `Resampled to ${resample.outputFrameCount} frames at ${OUTPUT_FPS} fps`,
    );

    await beginStage(workspace, 'composing');
    await workspace.update({ status: 'composing' });
    const cameraTrack = buildCameraTrack(timeline.events, resample.outputDurationMs, viewport);
    const cursorTrack = buildCursorTrack(timeline.events, viewport);
    const feedbackTrack = buildClickFeedbackTrack(timeline.events);
    const cursorEvents = timeline.events.filter(isCursorBearingEvent);
    const cursorAuditRequests = cursorActionFrameRequests(
      timeline.events,
      OUTPUT_FPS,
      resample.outputFrameCount,
    );
    const cursorLandingIndices = new Set(
      cursorAuditRequests
        .filter((request) =>
          request.event.kind === 'click'
            ? request.role === 'mouse-down'
            : request.role === 'path-completion',
        )
        .map((request) => request.outputIndex),
    );
    await writeFile(
      `${workspace.compositionDirectory}/camera-track.json`,
      `${JSON.stringify(cameraTrack, null, 2)}\n`,
    );
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
      cursorLandingIndices,
    );
    const loader = await SequentialSourceImageLoader.create(
      workspace.captureDirectory,
      resample.sourcePixelWidth,
      resample.sourcePixelHeight,
    );
    let validated: Awaited<ReturnType<typeof validateEncodedVideo>> | undefined;
    let cursorAuditResult: CursorActionAuditResult | undefined;
    let decodedCursorProofs: DecodedCursorProofRecord[] = [];
    await beginStage(workspace, 'encoding');
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
        await beginStage(workspace, 'validating-output');
        await workspace.update({ status: 'validating' });
        try {
          validated = await validateEncodedVideo({
            file,
            ffprobe,
            ffmpeg,
            width: OUTPUT_WIDTH,
            height: OUTPUT_HEIGHT,
            fps: OUTPUT_FPS,
            frameCount: resample.outputFrameCount,
          });
        } catch (error) {
          throw normalizeRenderError(error, {
            code: 'OUTPUT_VALIDATION_FAILED',
            stage: 'validating-output',
          });
        }
        await writeFile(
          `${workspace.encodeDirectory}/ffprobe.json`,
          `${JSON.stringify(validated.ffprobeJson, null, 2)}\n`,
        );
        if (!cursorAuditResult) {
          throw new Error('OUTPUT_VALIDATION_FAILED: Cursor action audit did not complete');
        }
        decodedCursorProofs =
          cursorAuditResult.proofs.length > 0
            ? await decodeCursorProofFrames({
                videoFile: file,
                ffmpeg,
                compositionDirectory: workspace.compositionDirectory,
                proofs: cursorAuditResult.proofs,
              })
            : [];
        await completeStage(
          workspace,
          options,
          'validating-output',
          'Validated H.264 MP4 and decoded cursor proofs',
          { decodedCursorProofs: decodedCursorProofs.length },
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
    const auditConsumer = await CursorActionAuditConsumer.create({
      outputDirectory: workspace.compositionDirectory,
      compositor,
      viewport,
      events: timeline.events,
      requests: cursorAuditRequests,
      delegate: encoder,
    });
    let compositionSummary: Awaited<ReturnType<typeof runComposition>> | undefined;
    try {
      compositionSummary = await runComposition({
        frames: planReader.frames(),
        sourceWidth: resample.sourcePixelWidth,
        sourceHeight: resample.sourcePixelHeight,
        loader,
        compositor,
        consumer: auditConsumer,
      });
      cursorAuditResult = await auditConsumer.finish();
      assertCursorSynchronization(cursorAuditResult, cursorEvents.length);
      await completeStage(
        workspace,
        options,
        'composing',
        `Verified ${cursorAuditResult.statistics.total} cursor-bearing actions`,
        {
          measurements: cursorAuditResult.statistics.byKind,
          landingError: cursorAuditResult.statistics.errorDistanceOutputPx,
          insideTargetCount: cursorAuditResult.statistics.insideTargetCount,
        },
      );
      encoded = await encoder.finalize();
      await completeStage(workspace, options, 'encoding', 'Encoded H.264 MP4', {
        backpressure: encoded.backpressure,
      });
    } catch (error) {
      await auditConsumer.abort().catch(() => undefined);
      await encoder.abort(error);
      throw normalizeRenderError(error, {
        code: 'ENCODE_FAILED',
        stage: cursorAuditResult ? 'encoding' : 'composing',
      });
    } finally {
      clearInterval(rssTimer);
    }
    rssSamples.push(process.memoryUsage().rss);
    if (!validated) throw new Error('OUTPUT_VALIDATION_FAILED: No validated video result');
    if (!cursorAuditResult || !compositionSummary) {
      throw new Error('OUTPUT_VALIDATION_FAILED: Composition diagnostics are incomplete');
    }
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
    await writeFile(
      `${workspace.compositionDirectory}/manifest.json`,
      `${JSON.stringify(
        {
          schemaVersion: 1,
          frameCount: compositionSummary.framesProcessed,
          bytesProcessed: compositionSummary.bytesProcessed,
          sourceImages: compositionSummary.sourceImages,
          rollingRgbaSha256: cursorAuditResult.rollingRgbaSha256,
          cursorActionLandings: cursorAuditResult.statistics,
          decodedCursorProofCount: decodedCursorProofs.length,
        },
        null,
        2,
      )}\n`,
    );
    await beginStage(workspace, 'publishing-output');
    await completeStage(workspace, options, 'publishing-output', 'Published output atomically');
    await beginStage(workspace, 'cleaning-up');
    const renderDurationMs = performance.now() - startedAt;
    const parentRssPeakBytes = Math.max(...rssSamples);
    const compositionFps = compositionSummary.framesProcessed / (encoded.executionMs / 1000);
    const warnings: RenderWarning[] = [
      {
        code: 'CDP_EXPERIMENTAL_SURFACE',
        message:
          'CDP screencast capture is Experimental and pinned to the recorded browser version.',
      },
      {
        code: 'CAPTURE_VERSION_SENSITIVE',
        message: 'Forced device-scale capture passed its genuine-2x painted-pixel proof.',
      },
      ...(capabilities.gplEnabled || capabilities.libx264Enabled
        ? [
            {
              code: 'SYSTEM_FFMPEG_GPL_BUILD' as const,
              message: 'The detected system FFmpeg build is GPL-conditioned and includes libx264.',
            },
          ]
        : []),
      ...(compositionFps < 8
        ? [
            {
              code: 'SLOW_COMPOSITION' as const,
              message: `Composition and encoding throughput was ${compositionFps.toFixed(3)} fps.`,
            },
          ]
        : []),
      ...(parentRssPeakBytes > 1024 ** 3
        ? [
            {
              code: 'HIGH_PARENT_MEMORY' as const,
              message: `Parent RSS peaked at ${parentRssPeakBytes} bytes.`,
            },
          ]
        : []),
      ...(ffmpegRssPeakBytes > 1024 ** 3
        ? [
            {
              code: 'HIGH_ENCODER_MEMORY' as const,
              message: `FFmpeg RSS peaked at ${ffmpegRssPeakBytes} bytes.`,
            },
          ]
        : []),
      ...(options.keepArtifacts
        ? [
            {
              code: 'WORKSPACE_PRESERVED' as const,
              message: `Render workspace preserved at ${workspace.directory}.`,
            },
          ]
        : []),
    ];
    const result: RenderDemoResult = {
      success: true,
      outputPath: encoded.outputPath,
      outputBytes: encoded.byteLength,
      outputSha256: encoded.sha256,
      durationSeconds: video.durationSeconds,
      frameCount: encoded.frameCount,
      fps: OUTPUT_FPS,
      actionCount: timeline.events.length,
      captureFrameCount: capture.manifest.frameCount,
      cursorActionMeasurements: cursorAuditResult.statistics.byKind,
      renderDurationMs,
      warnings,
      ...(options.keepArtifacts ? { artifactsPath: workspace.directory } : {}),
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
        cursorActionLandings: cursorAuditResult.statistics.byKind,
        cursorActionFailures: cursorAuditResult.statistics.failures,
        rgbaRollingSha256: cursorAuditResult.rollingRgbaSha256,
        decodedCursorProofs: decodedCursorProofs.length,
        fullyVisibleTargets: cursorAuditResult.measurements.filter(
          (measurement) => Math.abs(measurement.targetVisibleFraction - 1) <= 1e-7,
        ).length,
        encoder: encoded.backpressure,
        parentRssPeakBytes,
        ...(ffmpegRssPeakBytes > 0 ? { ffmpegRssPeakBytes } : {}),
      },
    };
    await workspace.finishStage('cleaning-up');
    await workspace.update({ status: 'completed', completedAt: new Date().toISOString() });
    options.onStage?.({
      stage: 'cleaning-up',
      status: 'completed',
      message: options.keepArtifacts ? 'Preserved render workspace' : 'Cleaned render workspace',
    });
    if (!options.keepArtifacts) await workspace.cleanup();
    return result;
  } catch (error) {
    await encoder?.abort(error).catch(() => undefined);
    const normalized = abortController.signal.aborted
      ? new RenderError({
          code: 'RENDER_ABORTED',
          stage: 'cleaning-up',
          message: 'Render was interrupted',
          cause: error,
        })
      : normalizeRenderError(error, { code: 'INTERNAL_ERROR', stage: 'cleaning-up' });
    const terminalStatus = abortController.signal.aborted ? 'aborted' : 'failed';
    await workspace.finishRunningStages(terminalStatus).catch(() => undefined);
    await workspace.startStage('cleaning-up').catch(() => undefined);
    const publicError = normalized.withArtifactsPath(workspace.directory);
    await writeFailureDiagnostics(
      workspace,
      publicError,
      completedActions,
      options.plan.actions.length,
    ).catch(() => undefined);
    await workspace.finishStage('cleaning-up').catch(() => undefined);
    await workspace
      .update({
        status: terminalStatus,
        completedAt: new Date().toISOString(),
        completedActions,
        failure: {
          code: publicError.code,
          message: publicError.message,
          stage: publicError.stage,
          ...(publicError.actionIndex === undefined
            ? {}
            : { actionIndex: publicError.actionIndex }),
          ...(publicError.actionKind === undefined ? {} : { actionKind: publicError.actionKind }),
        },
      })
      .catch(() => undefined);
    throw publicError;
  } finally {
    process.off('SIGINT', abort);
    process.off('SIGTERM', abort);
  }
}
