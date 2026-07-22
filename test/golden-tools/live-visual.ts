import { readFile, stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createCanvas, loadImage } from '@napi-rs/canvas';
import type { CursorActionLandingMeasurement } from '../../src/compositor/cursor-action-landing.js';
import { drawStudioGradient } from '../../src/compositor/gradient-background.js';
import {
  STUDIO_BROWSER_WINDOW_RECT,
  STUDIO_TOOLBAR,
  STUDIO_TRAFFIC_LIGHTS,
} from '../../src/compositor/studio-layout.js';
import {
  createStudioWindowShadowLayer,
  STUDIO_SHADOW_LAYER_RECT,
} from '../../src/compositor/window-shadow.js';
import type { CursorProofFrameRecord } from '../../src/render/cursor-action-audit.js';
import type { DecodedCursorProofRecord } from '../../src/render/mp4-cursor-proof.js';
import type { TimelineDocument } from '../../src/timeline/types.js';
import { GoldenError } from './types.js';

export interface LiveVisualVerificationResult {
  passed: true;
  authority: 'real-public-render-structural';
  environment: {
    playwrightVersion: string;
    chromiumVersion: string;
    nodeVersion: string;
    platform: string;
    architecture: string;
  };
  capture: {
    cssViewport: { width: number; height: number };
    devicePixelRatio: number;
    jpegDimensions: { width: number; height: number };
    genuinePaintedScale: boolean;
    frameCount: number;
  };
  timelineKinds: Record<string, number>;
  cursorMeasurements: { moveTo: number; click: number; type: number; failures: number };
  actualPixelContracts: Record<string, boolean>;
  encodedProofs: {
    count: number;
    indexesCorrespond: boolean;
    rgbMeanAbsoluteErrorMax: number;
    rgbPsnrMin: number;
    maximumChannelError: number;
  };
  output: { frameCount: number; durationSeconds: number; file: string };
  workspace: string;
}

export async function verifyLiveWorkspace(
  workspace: string,
  outputFile: string,
): Promise<LiveVisualVerificationResult> {
  const root = resolve(workspace);
  const [timeline, capture, resample, composition, landing, proofDocument, decoded, encoding] =
    await Promise.all([
      json<TimelineDocument>(root, 'capture/timeline.json'),
      json<LiveCaptureManifest>(root, 'capture/manifest.json'),
      json<{ outputFps: number; outputFrameCount: number }>(root, 'resample/manifest.json'),
      json<{ frameCount: number; cursorActionLandings: { failures: number } }>(
        root,
        'composition/manifest.json',
      ),
      json<{ measurements: CursorActionLandingMeasurement[] }>(
        root,
        'composition/cursor-action-landings.json',
      ),
      json<{ proofs: CursorProofFrameRecord[] }>(root, 'composition/cursor-proof-frames.json'),
      json<DecodedCursorProofRecord[]>(root, 'composition/mp4-cursor-proofs.json'),
      json<{ video: { frameCount: number; durationSeconds: number } }>(
        root,
        'encode/manifest.json',
      ),
    ]);
  const sourceFrames = parseJsonLines<{ index: number; timestampMs: number; file: string }>(
    await readFile(resolve(root, 'capture/frames.jsonl'), 'utf8'),
  );
  if (
    capture.viewport.width !== 1440 ||
    capture.viewport.height !== 900 ||
    capture.deviceScaleFactor !== 2 ||
    capture.observedBrowserMetrics.devicePixelRatio !== 2 ||
    capture.expectedFrameDimensions.pixelWidth !== 2880 ||
    capture.expectedFrameDimensions.pixelHeight !== 1800 ||
    capture.observedFrameDimensions.some(
      (dimensions) => dimensions.pixelWidth !== 2880 || dimensions.pixelHeight !== 1800,
    ) ||
    !capture.pixelScaleProof.passed ||
    capture.pixelScaleProof.expectedPaintedScale !== 2 ||
    capture.captureSurface.method !== 'chromium-force-device-scale-factor'
  ) {
    fail('Live capture did not prove genuine 2x browser painting');
  }
  if (
    sourceFrames.length !== capture.frameCount ||
    sourceFrames.some(
      (frame, index) =>
        frame.index !== index + 1 ||
        (index > 0 && frame.timestampMs <= (sourceFrames[index - 1]?.timestampMs ?? -1)),
    ) ||
    capture.queue.overflowCount !== 0 ||
    capture.queue.received !== capture.queue.acknowledged ||
    capture.queue.received !== capture.queue.written
  ) {
    fail('Live capture frame timestamps, counts, or queue invariants failed');
  }
  for (const frame of sourceFrames) await stat(resolve(root, 'capture', frame.file));
  if (resample.outputFps !== 30 || composition.frameCount !== resample.outputFrameCount) {
    fail('Live fixed-rate resample contract failed');
  }
  const kinds = Object.fromEntries(
    ['goto', 'wait', 'moveTo', 'click', 'type', 'scrollTo'].map((kind) => [
      kind,
      timeline.events.filter((event) => event.kind === kind).length,
    ]),
  );
  if (Object.values(kinds).some((count) => count < 1))
    fail('Live fixture did not execute all six actions');
  const byKind = {
    moveTo: landing.measurements.filter((value) => value.kind === 'moveTo').length,
    click: landing.measurements.filter((value) => value.kind === 'click').length,
    type: landing.measurements.filter((value) => value.kind === 'type').length,
  };
  if (byKind.moveTo !== 1 || byKind.click !== 2 || byKind.type !== 1) {
    fail('Live cursor-bearing measurement counts changed');
  }
  for (const measurement of landing.measurements) {
    if (
      measurement.errorDistanceOutputPx > 2 ||
      !measurement.hotspotInsideProjectedTarget ||
      Math.abs(measurement.targetVisibleFraction - 1) > 1e-7 ||
      measurement.cursorPixelsChanged < 1
    ) {
      fail(`${measurement.eventId} failed its live cursor pixel gate`);
    }
    if (
      measurement.kind === 'moveTo' &&
      (!measurement.pointerEnterObserved ||
        !measurement.heldAtActionCompletion ||
        !measurement.heldUntilNextCursorAction)
    ) {
      fail('Live moveTo did not preserve pointerenter and terminal hold');
    }
    if (measurement.kind === 'type' && !measurement.focusVerified) {
      fail('Live type target did not retain browser focus');
    }
  }
  if (composition.cursorActionLandings.failures !== 0) fail('Live cursor audit reported failures');
  const landingProofs = landing.measurements.map((measurement) => {
    const role = measurement.kind === 'click' ? 'mouse-down' : 'path-completion';
    const proof = proofDocument.proofs.find(
      (candidate) => candidate.eventId === measurement.eventId && candidate.role === role,
    );
    if (!proof) fail(`${measurement.eventId} is missing its live RGBA proof`);
    return proof;
  });
  const actualPixelContracts = await livePixelContracts(root, landingProofs, proofDocument.proofs);
  if (Object.values(actualPixelContracts).some((passed) => !passed)) {
    fail('A live actual-pixel structural contract failed', { actualPixelContracts });
  }
  if (decoded.length !== proofDocument.proofs.length) fail('Encoded proof count changed');
  for (const proof of decoded) {
    if (
      proof.compositorOutputIndex !== proof.encoderWriteIndex ||
      proof.encoderWriteIndex !== proof.decodedOutputIndex ||
      proof.outputIndex !== proof.decodedOutputIndex ||
      !proof.correspondsToOutputIndex
    ) {
      fail(`Encoded proof frame ${proof.outputIndex} shifted or failed correspondence`);
    }
    await stat(resolve(root, 'composition', proof.decodedFrameFile));
  }
  await stat(resolve(outputFile));
  return {
    passed: true,
    authority: 'real-public-render-structural',
    environment: {
      playwrightVersion: capture.playwrightVersion,
      chromiumVersion: capture.chromiumVersion,
      nodeVersion: capture.nodeVersion,
      platform: process.platform,
      architecture: process.arch,
    },
    capture: {
      cssViewport: capture.viewport,
      devicePixelRatio: capture.observedBrowserMetrics.devicePixelRatio,
      jpegDimensions: {
        width: capture.expectedFrameDimensions.pixelWidth,
        height: capture.expectedFrameDimensions.pixelHeight,
      },
      genuinePaintedScale: capture.pixelScaleProof.passed,
      frameCount: capture.frameCount,
    },
    timelineKinds: kinds,
    cursorMeasurements: { ...byKind, failures: composition.cursorActionLandings.failures },
    actualPixelContracts,
    encodedProofs: {
      count: decoded.length,
      indexesCorrespond: true,
      rgbMeanAbsoluteErrorMax: Math.max(...decoded.map((proof) => proof.rgbMeanAbsoluteError)),
      rgbPsnrMin: Math.min(...decoded.map((proof) => proof.rgbPsnr)),
      maximumChannelError: Math.max(...decoded.map((proof) => proof.maximumChannelError)),
    },
    output: {
      frameCount: encoding.video.frameCount,
      durationSeconds: encoding.video.durationSeconds,
      file: resolve(outputFile),
    },
    workspace: root,
  };
}

async function livePixelContracts(
  workspace: string,
  landingProofs: readonly CursorProofFrameRecord[],
  allProofs: readonly CursorProofFrameRecord[],
): Promise<Record<string, boolean>> {
  const first = landingProofs[0];
  if (!first) fail('No live landing proof is available for pixel inspection');
  const image = await loadImage(resolve(workspace, 'composition', first.fullFrameFile));
  const canvas = createCanvas(image.width, image.height);
  canvas.getContext('2d').drawImage(image, 0, 0);
  const pixels = new Uint8Array(canvas.data());
  const baselineCanvas = createCanvas(1920, 1080);
  const baselineContext = baselineCanvas.getContext('2d');
  drawStudioGradient(baselineContext);
  baselineContext.drawImage(
    createStudioWindowShadowLayer(),
    STUDIO_SHADOW_LAYER_RECT.x,
    STUDIO_SHADOW_LAYER_RECT.y,
  );
  const baseline = new Uint8Array(baselineCanvas.data());
  const corners = [
    [STUDIO_BROWSER_WINDOW_RECT.x, STUDIO_BROWSER_WINDOW_RECT.y],
    [
      STUDIO_BROWSER_WINDOW_RECT.x + STUDIO_BROWSER_WINDOW_RECT.width - 1,
      STUDIO_BROWSER_WINDOW_RECT.y,
    ],
    [
      STUDIO_BROWSER_WINDOW_RECT.x,
      STUDIO_BROWSER_WINDOW_RECT.y + STUDIO_BROWSER_WINDOW_RECT.height - 1,
    ],
    [
      STUDIO_BROWSER_WINDOW_RECT.x + STUDIO_BROWSER_WINDOW_RECT.width - 1,
      STUDIO_BROWSER_WINDOW_RECT.y + STUDIO_BROWSER_WINDOW_RECT.height - 1,
    ],
  ] as const;
  const rippleProof = allProofs.find((proof) => proof.activeRipples.length > 0);
  const ripple = rippleProof?.activeRipples[0];
  let ripplePixels = false;
  if (rippleProof && ripple) {
    const rippleImage = await loadImage(
      resolve(workspace, 'composition', rippleProof.fullFrameFile),
    );
    const rippleCanvas = createCanvas(1920, 1080);
    rippleCanvas.getContext('2d').drawImage(rippleImage, 0, 0);
    const rippleData = new Uint8Array(rippleCanvas.data());
    const sample = pixel(
      rippleData,
      Math.round(ripple.screenX + ripple.radius),
      Math.round(ripple.screenY),
    );
    ripplePixels = (sample[0] ?? 0) + (sample[1] ?? 0) + (sample[2] ?? 0) > 300;
  }
  return {
    outputOpaque: allOpaque(pixels),
    gradientOutsideWindow: !sameRgb(pixel(pixels, 0, 0), pixel(pixels, 1919, 1079)),
    roundedMaskMatchesBackgroundAndShadow: corners.every(([x, y]) =>
      rgbNear(pixel(pixels, x, y), pixel(baseline, x, y), 2),
    ),
    shadowOutsideWindow: !sameRgb(pixel(pixels, 960, 1040), gradientPixel(960, 1040)),
    toolbarPresent: rgbNear(pixel(pixels, 960, 90), [245, 245, 247, 255], 2),
    trafficLightsPresent: STUDIO_TRAFFIC_LIGHTS.centersX.every((x, index) =>
      rgbNear(
        pixel(
          pixels,
          STUDIO_BROWSER_WINDOW_RECT.x + x,
          STUDIO_BROWSER_WINDOW_RECT.y + STUDIO_TRAFFIC_LIGHTS.centerY,
        ),
        hex(STUDIO_TRAFFIC_LIGHTS.colors[index] ?? '#000000'),
        2,
      ),
    ),
    borderAboveSurface: !rgbNear(
      pixel(pixels, 960, STUDIO_BROWSER_WINDOW_RECT.y),
      hex(STUDIO_TOOLBAR.background),
      1,
    ),
    rippleAboveBrowserPixels: ripplePixels,
    cursorAboveRipple: landingProofs.every(
      (proof) => proof.cursorRenderedSize.width === 30 && proof.cursorRenderedSize.height === 38,
    ),
    targetPixelsBeneathCursor: landingProofs.every(
      (proof) =>
        proof.targetPixelEvidence.sampledPixels > 0 &&
        proof.targetPixelEvidence.rgbStandardDeviation >= 10 &&
        proof.targetPixelEvidence.nonUniformFraction >= 0.05,
    ),
  };
}

let gradient: Uint8Array | undefined;
function gradientPixel(x: number, y: number): readonly number[] {
  if (!gradient) {
    const canvas = createCanvas(1920, 1080);
    drawStudioGradient(canvas.getContext('2d'));
    gradient = new Uint8Array(canvas.data());
  }
  return pixel(gradient, x, y);
}

function pixel(data: Uint8Array, x: number, y: number): readonly number[] {
  const offset = (y * 1920 + x) * 4;
  return [
    data[offset] ?? -1,
    data[offset + 1] ?? -1,
    data[offset + 2] ?? -1,
    data[offset + 3] ?? -1,
  ];
}

function sameRgb(left: readonly number[], right: readonly number[]): boolean {
  return left[0] === right[0] && left[1] === right[1] && left[2] === right[2];
}

function allOpaque(data: Uint8Array): boolean {
  for (let offset = 3; offset < data.byteLength; offset += 4) {
    if (data[offset] !== 255) return false;
  }
  return true;
}

function rgbNear(left: readonly number[], right: readonly number[], tolerance: number): boolean {
  return [0, 1, 2].every(
    (channel) => Math.abs((left[channel] ?? -1000) - (right[channel] ?? 1000)) <= tolerance,
  );
}

function hex(value: string): readonly number[] {
  const match = /^#([\da-f]{2})([\da-f]{2})([\da-f]{2})$/iu.exec(value);
  if (!match) throw new Error(`Expected hex color ${value}`);
  return [
    Number.parseInt(match[1] ?? '', 16),
    Number.parseInt(match[2] ?? '', 16),
    Number.parseInt(match[3] ?? '', 16),
    255,
  ];
}

async function json<T>(root: string, file: string): Promise<T> {
  return JSON.parse(await readFile(resolve(root, file), 'utf8')) as T;
}

function parseJsonLines<T>(source: string): T[] {
  return source
    .trim()
    .split(/\r?\n/u)
    .map((line) => JSON.parse(line) as T);
}

function fail(message: string, details?: Record<string, unknown>): never {
  throw new GoldenError('LIVE_VISUAL_CONTRACT_FAILED', message, details);
}

interface LiveCaptureManifest {
  playwrightVersion: string;
  chromiumVersion: string;
  nodeVersion: string;
  viewport: { width: number; height: number };
  deviceScaleFactor: number;
  observedBrowserMetrics: { devicePixelRatio: number };
  captureSurface: { method: string };
  expectedFrameDimensions: { pixelWidth: number; pixelHeight: number };
  observedFrameDimensions: Array<{ pixelWidth: number; pixelHeight: number }>;
  pixelScaleProof: { passed: boolean; expectedPaintedScale: number };
  frameCount: number;
  queue: {
    received: number;
    acknowledged: number;
    written: number;
    overflowCount: number;
  };
}
