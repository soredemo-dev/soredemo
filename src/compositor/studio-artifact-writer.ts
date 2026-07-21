import { createHash } from 'node:crypto';
import type { FileHandle } from 'node:fs/promises';
import { mkdir, open, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { ClickTimelineEvent } from '../timeline/types.js';
import { projectCssPoint } from './camera-projection.js';
import { measureTargetFraming } from './camera-statistics.js';
import type { Size, TargetFramingMeasurement } from './camera-types.js';
import { type CursorLandingMeasurement, measureCursorLanding } from './landing-statistics.js';
import { assertRawRgbaLayout } from './rgba.js';
import type { StudioFrameCompositor, StudioRawRgbaFrame } from './studio-frame-compositor.js';
import { studioCursorHotspot } from './studio-frame-compositor.js';
import { STUDIO_BROWSER_CONTENT_RECT, STUDIO_BROWSER_WINDOW_RECT } from './studio-layout.js';
import type { FrameConsumer, RawRgbaFrame, SnapshotRecord } from './types.js';

export interface RippleMeasurement {
  clickId: string;
  outputIndex: number;
  outputTimestampMs: number;
  mouseDownMs: number;
  progress: number;
  radius: number;
  opacity: number;
  screenX: number;
  screenY: number;
}

export class StudioDiagnosticSink implements FrameConsumer {
  private expectedIndex = 0;
  private readonly rolling = createHash('sha256');
  private readonly landing: CursorLandingMeasurement[] = [];
  private readonly framing: TargetFramingMeasurement[] = [];
  private readonly rippleMeasurements: RippleMeasurement[] = [];
  private readonly ripplesStarted = new Set<string>();
  private readonly rippleFramesByClick = new Map<string, number>();
  private readonly snapshots: SnapshotRecord[] = [];
  private readonly cursorFrames = { visible: 0, hidden: 0, exact: 0, linear: 0, held: 0 };
  private rippleVisibleFrameCount = 0;
  private maxSimultaneousRipples = 0;
  private maskLeakFrames = 0;
  private blackOutsideWindowFrames = 0;
  private closed = false;

  private constructor(
    private readonly outputDirectory: string,
    private readonly file: FileHandle,
    private readonly compositor: StudioFrameCompositor,
    private readonly viewport: Size,
    private readonly landingEvents: ReadonlyMap<number, readonly ClickTimelineEvent[]>,
    private readonly snapshotPurposes: ReadonlyMap<number, string>,
  ) {}

  static async create(options: {
    outputDirectory: string;
    compositor: StudioFrameCompositor;
    viewport: Size;
    landingEvents: ReadonlyMap<number, readonly ClickTimelineEvent[]>;
    snapshotPurposes: ReadonlyMap<number, string>;
  }): Promise<StudioDiagnosticSink> {
    await mkdir(resolve(options.outputDirectory, 'snapshots'), { recursive: true });
    const file = await open(resolve(options.outputDirectory, 'frame-hashes.jsonl'), 'wx');
    return new StudioDiagnosticSink(
      options.outputDirectory,
      file,
      options.compositor,
      options.viewport,
      options.landingEvents,
      options.snapshotPurposes,
    );
  }

  async consume(rawFrame: RawRgbaFrame): Promise<void> {
    const frame = rawFrame as StudioRawRgbaFrame;
    if (this.closed) throw new Error('Studio diagnostic sink is closed');
    if (frame.outputIndex !== this.expectedIndex) {
      throw new Error(`Expected studio frame ${this.expectedIndex}, received ${frame.outputIndex}`);
    }
    assertRawRgbaLayout(frame);
    this.verifyBackgroundAndMask(frame);
    const rgbaSha256 = createHash('sha256').update(frame.data).digest('hex');
    await this.file.write(
      `${JSON.stringify({
        outputIndex: frame.outputIndex,
        outputTimestampMs: frame.outputTimestampMs,
        sourceIndex: frame.sourceIndex,
        sourceTimestampMs: frame.sourceTimestampMs,
        cameraSegmentId: frame.camera.segmentId,
        cameraPhase: frame.camera.phase,
        cameraZoom: frame.camera.zoom,
        cameraCenterCssX: frame.camera.centerCssX,
        cameraCenterCssY: frame.camera.centerCssY,
        cursorVisible: frame.cursor.visible,
        cursorInterpolation: frame.cursor.interpolation,
        activeRippleCount: frame.ripples.length,
        rgbaSha256,
      })}\n`,
    );
    this.rolling.update(frame.data);
    if (frame.cursor.visible) this.cursorFrames.visible += 1;
    else this.cursorFrames.hidden += 1;
    if (frame.cursor.interpolation !== 'hidden') this.cursorFrames[frame.cursor.interpolation] += 1;
    if (frame.ripples.length > 0) this.rippleVisibleFrameCount += 1;
    this.maxSimultaneousRipples = Math.max(this.maxSimultaneousRipples, frame.ripples.length);
    for (const ripple of frame.ripples) {
      this.ripplesStarted.add(ripple.clickId);
      this.rippleFramesByClick.set(
        ripple.clickId,
        (this.rippleFramesByClick.get(ripple.clickId) ?? 0) + 1,
      );
      this.rippleMeasurements.push({
        clickId: ripple.clickId,
        outputIndex: frame.outputIndex,
        outputTimestampMs: frame.outputTimestampMs,
        mouseDownMs: ripple.mouseDownMs,
        progress: ripple.progress,
        radius: ripple.radius,
        opacity: ripple.opacity,
        screenX: ripple.screenX,
        screenY: ripple.screenY,
      });
    }

    for (const click of this.landingEvents.get(frame.outputIndex) ?? []) {
      if (!frame.cursorPlacement) throw new Error(`${click.id} has no studio cursor placement`);
      if (!frame.cursorPixelsChanged || frame.cursorPixelsChanged < 1) {
        throw new Error(`${click.id} cursor did not change studio-composited pixels`);
      }
      const clickScreen = projectCssPoint(
        click.clickPoint,
        frame.camera,
        this.viewport,
        STUDIO_BROWSER_CONTENT_RECT,
      );
      this.landing.push(
        measureCursorLanding({
          click,
          outputFrame: {
            outputIndex: frame.outputIndex,
            outputTimestampMs: frame.outputTimestampMs,
            sourceIndex: frame.sourceIndex,
            sourceFile: '',
            sourceTimestampMs: frame.sourceTimestampMs,
            signedSourceDeltaMs: frame.sourceTimestampMs - frame.outputTimestampMs,
            absoluteSourceDeltaMs: Math.abs(frame.sourceTimestampMs - frame.outputTimestampMs),
            relation:
              frame.sourceTimestampMs < frame.outputTimestampMs
                ? 'before'
                : frame.sourceTimestampMs > frame.outputTimestampMs
                  ? 'after'
                  : 'exact',
          },
          cursor: frame.cursor,
          cursorScreen: studioCursorHotspot(frame),
          clickScreen,
        }),
      );
      this.framing.push(
        measureTargetFraming({
          click,
          outputIndex: frame.outputIndex,
          camera: frame.camera,
          viewport: this.viewport,
          contentRect: STUDIO_BROWSER_CONTENT_RECT,
        }),
      );
    }

    const purpose = this.snapshotPurposes.get(frame.outputIndex);
    if (purpose) {
      const png = this.compositor.png();
      const file = `snapshots/frame-${String(frame.outputIndex).padStart(6, '0')}.png`;
      await writeFile(resolve(this.outputDirectory, file), png, { flag: 'wx' });
      this.snapshots.push({
        purpose,
        outputIndex: frame.outputIndex,
        outputTimestampMs: frame.outputTimestampMs,
        sourceIndex: frame.sourceIndex,
        sourceTimestampMs: frame.sourceTimestampMs,
        file,
        pngSha256: createHash('sha256').update(png).digest('hex'),
      });
    }
    this.expectedIndex += 1;
  }

  async finish() {
    if (this.closed) throw new Error('Studio diagnostic sink is already closed');
    this.closed = true;
    await this.file.close();
    return {
      frameCount: this.expectedIndex,
      rollingRgbaSha256: this.rolling.digest('hex'),
      landing: [...this.landing],
      framing: [...this.framing],
      rippleMeasurements: [...this.rippleMeasurements],
      ripple: {
        ripplesStarted: this.ripplesStarted.size,
        visibleFrameCount: this.rippleVisibleFrameCount,
        maxSimultaneousRipples: this.maxSimultaneousRipples,
        frameCountByClick: Object.fromEntries([...this.rippleFramesByClick].sort()),
      },
      snapshots: [...this.snapshots],
      cursorFrames: { ...this.cursorFrames },
      maskLeakFrames: this.maskLeakFrames,
      blackOutsideWindowFrames: this.blackOutsideWindowFrames,
    };
  }

  async abort(): Promise<void> {
    if (!this.closed) await this.file.close();
    this.closed = true;
  }

  private verifyBackgroundAndMask(frame: StudioRawRgbaFrame): void {
    const outside = [
      [0, 0],
      [1919, 0],
      [0, 1079],
      [1919, 1079],
    ] as const;
    if (outside.some(([x, y]) => isBlack(frame.data, x, y))) {
      this.blackOutsideWindowFrames += 1;
    }
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
    if (
      corners.some(([x, y]) => {
        const pixel = rgba(frame.data, x, y);
        return pixel[0] >= 235 && pixel[1] >= 235 && pixel[2] >= 235;
      })
    ) {
      this.maskLeakFrames += 1;
    }
  }
}

function rgba(data: Uint8Array, x: number, y: number): [number, number, number, number] {
  const offset = (y * 1920 + x) * 4;
  return [data[offset] ?? 0, data[offset + 1] ?? 0, data[offset + 2] ?? 0, data[offset + 3] ?? 0];
}

function isBlack(data: Uint8Array, x: number, y: number): boolean {
  const pixel = rgba(data, x, y);
  return pixel[0] === 0 && pixel[1] === 0 && pixel[2] === 0 && pixel[3] === 255;
}

export async function writeStudioArtifacts(options: {
  outputDirectory: string;
  manifest: unknown;
  landing: readonly CursorLandingMeasurement[];
  framing: readonly TargetFramingMeasurement[];
  ripples: readonly RippleMeasurement[];
}): Promise<void> {
  for (const [file, value] of [
    ['manifest.json', options.manifest],
    ['landing-measurements.json', options.landing],
    ['target-framing.json', options.framing],
    ['ripple-measurements.json', options.ripples],
  ] as const) {
    await writeFile(resolve(options.outputDirectory, file), `${JSON.stringify(value, null, 2)}\n`, {
      flag: 'wx',
    });
  }
}
