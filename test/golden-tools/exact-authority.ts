import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createCanvas, type Image, loadImage } from '@napi-rs/canvas';
import { SequentialCameraEvaluator } from '../../src/compositor/camera-evaluator.js';
import type { CameraTrack } from '../../src/compositor/camera-types.js';
import {
  buildClickFeedbackTrack,
  SequentialClickFeedbackEvaluator,
} from '../../src/compositor/click-feedback-track.js';
import { loadCursorAsset, STUDIO_CURSOR } from '../../src/compositor/cursor-asset.js';
import { SequentialCursorEvaluator } from '../../src/compositor/cursor-track.js';
import { drawStudioGradient } from '../../src/compositor/gradient-background.js';
import {
  StudioFrameCompositor,
  type StudioRawRgbaFrame,
} from '../../src/compositor/studio-frame-compositor.js';
import {
  STUDIO_BROWSER_CONTENT_RECT,
  STUDIO_BROWSER_WINDOW_RECT,
  STUDIO_TOOLBAR,
  STUDIO_TOOLBAR_HEIGHT,
  STUDIO_TRAFFIC_LIGHTS,
  STUDIO_WINDOW_RADIUS,
} from '../../src/compositor/studio-layout.js';
import { OUTPUT_HEIGHT, OUTPUT_WIDTH } from '../../src/compositor/types.js';
import type { ResampledFrameRecord } from '../../src/resample/types.js';
import { buildCursorTrack } from '../../src/timeline/cursor-track-validation.js';
import type { TimelineDocument } from '../../src/timeline/types.js';
import { validateTimelineDocument } from '../../src/timeline/validation.js';
import {
  readCanonicalInputManifest,
  safeInputPath,
  verifyCanonicalInputHashes,
} from './input-hashes.js';
import { inspectExactProfile, sha256, stableJson } from './profile.js';
import { selectCanonicalFrames } from './semantic-selection.js';
import type { ExactGoldenManifest, GoldenFrameRecord } from './types.js';

export const CANONICAL_INPUT_ROOT = resolve('test/golden-input/studio-v1');
export const CHECKED_GOLDEN_ROOT = resolve('test/golden/macos-arm64-canvas-1.0.2');
export const GOLDEN_CANDIDATE_ROOT = resolve('.tmp/golden-candidate');

export interface ExactCandidateResult {
  manifest: ExactGoldenManifest;
  contactSheetFile: string;
}

export async function generateExactCandidate(
  outputRoot = GOLDEN_CANDIDATE_ROOT,
): Promise<ExactCandidateResult> {
  const inputManifest = await readCanonicalInputManifest(CANONICAL_INPUT_ROOT);
  const canonicalInputs = {
    ...(await verifyCanonicalInputHashes(CANONICAL_INPUT_ROOT, inputManifest)),
    'manifest.json#configuration': sha256(
      Buffer.from(
        stableJson({
          schemaVersion: inputManifest.schemaVersion,
          sourceWidth: inputManifest.sourceWidth,
          sourceHeight: inputManifest.sourceHeight,
          outputFps: inputManifest.outputFps,
          frameCount: inputManifest.frameCount,
        }),
      ),
    ),
  };
  const timeline = JSON.parse(
    await readFile(safeInputPath(CANONICAL_INPUT_ROOT, 'timeline.json'), 'utf8'),
  ) as TimelineDocument;
  validateTimelineDocument(timeline, 4000);
  const cameraTrack = JSON.parse(
    await readFile(safeInputPath(CANONICAL_INPUT_ROOT, 'camera-track.json'), 'utf8'),
  ) as CameraTrack;
  const records = parseJsonLines<ResampledFrameRecord>(
    await readFile(safeInputPath(CANONICAL_INPUT_ROOT, 'resample-plan.jsonl'), 'utf8'),
  );
  const selections = selectCanonicalFrames(records, timeline, cameraTrack);
  const cursorTrack = buildCursorTrack(timeline.events, cameraTrack.viewport);
  const cursorAsset = await loadCursorAsset(resolve('assets/cursor.svg'));
  const compositor = new StudioFrameCompositor(
    inputManifest.sourceWidth,
    inputManifest.sourceHeight,
    cameraTrack.viewport,
    cursorAsset,
    new SequentialCameraEvaluator(cameraTrack),
    new SequentialCursorEvaluator(cursorTrack),
    new SequentialClickFeedbackEvaluator(buildClickFeedbackTrack(timeline.events)),
    new Set(selections.map(({ record }) => record.outputIndex)),
  );
  const byOutput = new Map(
    selections.map((selection) => [selection.record.outputIndex, selection]),
  );
  const images = new Map<string, Image>();
  const frames: GoldenFrameRecord[] = [];
  const pngs = new Map<string, Buffer>();
  const structural = new StructuralAccumulator();
  await rm(outputRoot, { recursive: true, force: true });
  await mkdir(resolve(outputRoot, 'frames'), { recursive: true });

  for (const record of records) {
    const selection = byOutput.get(record.outputIndex);
    if (!selection) continue;
    let image = images.get(record.sourceFile);
    if (!image) {
      image = await loadImage(safeInputPath(CANONICAL_INPUT_ROOT, record.sourceFile));
      images.set(record.sourceFile, image);
    }
    const frame = compositor.compose(
      {
        outputIndex: record.outputIndex,
        outputTimestampMs: record.outputTimestampMs,
        sourceIndex: record.sourceIndex,
        sourceFile: record.sourceFile,
        sourceTimestampMs: record.sourceTimestampMs,
        signedSourceDeltaMs: record.signedSourceDeltaMs,
      },
      image,
    );
    const png = compositor.png();
    const file = `frames/${selection.purpose}.png`;
    await writeFile(resolve(outputRoot, file), png);
    pngs.set(selection.purpose, png);
    frames.push(frameRecord(selection.purpose, record, frame, file, png));
    structural.inspect(selection.purpose, frame);
  }
  const manifest: ExactGoldenManifest = {
    schemaVersion: 1,
    authority: 'exact-synthetic-compositor',
    profile: await inspectExactProfile(),
    canonicalInputs,
    frames,
    structuralAssertions: structural.finish(),
  };
  await writeFile(resolve(outputRoot, 'manifest.json'), stableJson(manifest));
  const contactSheetFile = resolve(outputRoot, 'contact-sheet.png');
  await writeFile(contactSheetFile, await contactSheet(frames, pngs));
  await writeFile(resolve(outputRoot, 'review.md'), reviewMarkdown(manifest));
  return { manifest, contactSheetFile };
}

function frameRecord(
  purpose: string,
  record: ResampledFrameRecord,
  frame: StudioRawRgbaFrame,
  file: string,
  png: Buffer,
): GoldenFrameRecord {
  return {
    purpose,
    outputIndex: record.outputIndex,
    outputTimestampMs: record.outputTimestampMs,
    sourceIndex: record.sourceIndex,
    sourceTimestampMs: record.sourceTimestampMs,
    sourceFile: record.sourceFile,
    file,
    pngSha256: sha256(png),
    rgbaSha256: sha256(frame.data),
    camera: {
      segmentId: frame.camera.segmentId,
      phase: frame.camera.phase,
      zoom: frame.camera.zoom,
      centerCssX: frame.camera.centerCssX,
      centerCssY: frame.camera.centerCssY,
    },
    cursor: {
      visible: frame.cursor.visible,
      interpolation: frame.cursor.interpolation,
      ...(frame.cursorPlacement
        ? {
            screenHotspotX: frame.cursorPlacement.hotspotScreenX,
            screenHotspotY: frame.cursorPlacement.hotspotScreenY,
          }
        : {}),
    },
    ripples: frame.ripples.map((ripple) => ({
      clickId: ripple.clickId,
      progress: ripple.progress,
      radius: ripple.radius,
      opacity: ripple.opacity,
    })),
    output: { width: OUTPUT_WIDTH, height: OUTPUT_HEIGHT, opaque: true },
  };
}

class StructuralAccumulator {
  private opacity = true;
  private gradient = false;
  private toolbar = false;
  private trafficLights = false;
  private roundedMask = false;
  private shadow = false;
  private border = false;
  private projectedSource = false;
  private ripple = false;
  private cursorAboveRipple = false;
  private cursorSize = true;

  inspect(purpose: string, frame: StudioRawRgbaFrame): void {
    this.opacity &&= allOpaque(frame.data);
    if (purpose === 'establish') {
      const background = gradientPixels();
      this.gradient =
        samePixel(frame.data, background, 0, 0) && samePixel(frame.data, background, 1919, 1079);
      this.toolbar = pixelNear(frame.data, 960, 90, hex(STUDIO_TOOLBAR.background), 1);
      this.trafficLights = STUDIO_TRAFFIC_LIGHTS.centersX.every((x, index) =>
        pixelNear(
          frame.data,
          STUDIO_BROWSER_WINDOW_RECT.x + x,
          STUDIO_BROWSER_WINDOW_RECT.y + STUDIO_TRAFFIC_LIGHTS.centerY,
          hex(STUDIO_TRAFFIC_LIGHTS.colors[index] ?? '#000000'),
          2,
        ),
      );
      this.roundedMask =
        !pixelNear(
          frame.data,
          STUDIO_BROWSER_WINDOW_RECT.x,
          STUDIO_BROWSER_WINDOW_RECT.y,
          hex(STUDIO_TOOLBAR.background),
          2,
        ) &&
        !pixelNear(
          frame.data,
          STUDIO_BROWSER_WINDOW_RECT.x,
          STUDIO_BROWSER_WINDOW_RECT.y + STUDIO_BROWSER_WINDOW_RECT.height - 1,
          [237, 233, 254],
          2,
        );
      this.shadow = !samePixel(frame.data, background, 960, 1040);
      this.border = !pixelNear(
        frame.data,
        960,
        STUDIO_BROWSER_WINDOW_RECT.y,
        hex(STUDIO_TOOLBAR.background),
        1,
      );
      this.projectedSource = pixelNear(
        frame.data,
        STUDIO_BROWSER_CONTENT_RECT.x + STUDIO_BROWSER_CONTENT_RECT.width / 2,
        STUDIO_BROWSER_CONTENT_RECT.y + STUDIO_BROWSER_CONTENT_RECT.height / 2,
        [124, 58, 237],
        2,
      );
    }
    if (purpose === 'click-ripple-start') {
      this.ripple = frame.ripples.length === 1;
      this.cursorAboveRipple = (frame.cursorPixelsChanged ?? 0) > 0;
    }
    if (frame.cursorPlacement) {
      this.cursorSize &&=
        frame.cursorPlacement.width === STUDIO_CURSOR.renderedWidth &&
        frame.cursorPlacement.height === STUDIO_CURSOR.renderedHeight;
    }
  }

  finish(): Record<string, boolean> {
    const assertions = {
      opaqueOutput: this.opacity,
      gradientOutsideWindow: this.gradient,
      toolbarGeometryAndColor: this.toolbar && STUDIO_TOOLBAR_HEIGHT === 52,
      trafficLightGeometryAndColor: this.trafficLights,
      roundedMaskPreventsLeakage: this.roundedMask && STUDIO_WINDOW_RADIUS === 22,
      shadowOutsideWindow: this.shadow,
      borderAboveWindow: this.border,
      browserContentUsesCameraProjection: this.projectedSource,
      rippleAboveBrowserContent: this.ripple,
      cursorAboveRipple: this.cursorAboveRipple,
      cursorRasterAndHotspot:
        this.cursorSize && STUDIO_CURSOR.hotspotX === 2 && STUDIO_CURSOR.hotspotY === 2,
    };
    if (Object.values(assertions).some((value) => !value)) {
      throw new Error(`Synthetic structural assertions failed: ${stableJson(assertions)}`);
    }
    return assertions;
  }
}

let cachedGradient: Uint8Array | undefined;
function gradientPixels(): Uint8Array {
  if (!cachedGradient) {
    const canvas = createCanvas(OUTPUT_WIDTH, OUTPUT_HEIGHT);
    drawStudioGradient(canvas.getContext('2d'));
    cachedGradient = new Uint8Array(canvas.data());
  }
  return cachedGradient;
}

function allOpaque(data: Uint8Array): boolean {
  for (let offset = 3; offset < data.byteLength; offset += 4) {
    if (data[offset] !== 255) return false;
  }
  return true;
}

function samePixel(left: Uint8Array, right: Uint8Array, x: number, y: number): boolean {
  const offset = (Math.floor(y) * OUTPUT_WIDTH + Math.floor(x)) * 4;
  return [0, 1, 2, 3].every((channel) => left[offset + channel] === right[offset + channel]);
}

function pixelNear(
  data: Uint8Array,
  x: number,
  y: number,
  expected: readonly number[],
  tolerance: number,
): boolean {
  const offset = (Math.floor(y) * OUTPUT_WIDTH + Math.floor(x)) * 4;
  return expected.every(
    (value, channel) => Math.abs((data[offset + channel] ?? -1000) - value) <= tolerance,
  );
}

function hex(value: string): readonly [number, number, number] {
  const match = /^#([\da-f]{2})([\da-f]{2})([\da-f]{2})$/iu.exec(value);
  if (!match) throw new Error(`Expected hex color, received ${value}`);
  return [
    Number.parseInt(match[1] ?? '', 16),
    Number.parseInt(match[2] ?? '', 16),
    Number.parseInt(match[3] ?? '', 16),
  ];
}

async function contactSheet(
  frames: readonly GoldenFrameRecord[],
  pngs: ReadonlyMap<string, Buffer>,
): Promise<Buffer> {
  const columns = 4;
  const cellWidth = 480;
  const cellHeight = 270;
  const gap = 12;
  const rows = Math.ceil(frames.length / columns);
  const canvas = createCanvas(
    columns * cellWidth + (columns + 1) * gap,
    rows * cellHeight + (rows + 1) * gap,
  );
  const context = canvas.getContext('2d');
  context.fillStyle = '#CBD5E1';
  context.fillRect(0, 0, canvas.width, canvas.height);
  for (const [index, frame] of frames.entries()) {
    const png = pngs.get(frame.purpose);
    if (!png) throw new Error(`Missing candidate PNG for ${frame.purpose}`);
    const image = await loadImage(png);
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
  return canvas.toBuffer('image/png');
}

function reviewMarkdown(manifest: ExactGoldenManifest): string {
  return `# Synthetic golden candidate review\n\nProfile: ${manifest.profile.name}\n\nThis candidate is unclassified. Review it as an intentional visual change, unexpected compositor regression, environment/version drift, or canonical input change before promotion.\n\nFrames:\n${manifest.frames.map((frame) => `- ${frame.purpose}: output ${frame.outputIndex}, RGBA ${frame.rgbaSha256}`).join('\n')}\n`;
}

function parseJsonLines<T>(source: string): T[] {
  return source
    .split(/\r?\n/u)
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as T);
}
