import { createHash } from 'node:crypto';
import type { FileHandle } from 'node:fs/promises';
import { mkdir, open, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { ClickTimelineEvent } from '../timeline/types.js';
import type { BaseFrameCompositor } from './base-frame-compositor.js';
import type { CameraRawRgbaFrame } from './camera-frame-compositor.js';
import { cameraCursorHotspot } from './camera-frame-compositor.js';
import { projectCssPoint } from './camera-projection.js';
import { measureTargetFraming } from './camera-statistics.js';
import type { Size, TargetFramingMeasurement } from './camera-types.js';
import { type CursorLandingMeasurement, measureCursorLanding } from './landing-statistics.js';
import { assertRawRgbaLayout } from './rgba.js';
import type { FrameConsumer, RawRgbaFrame, SnapshotRecord } from './types.js';

export interface CameraFrameHashRecord {
  outputIndex: number;
  outputTimestampMs: number;
  sourceIndex: number;
  sourceTimestampMs: number;
  cameraSegmentId: string;
  cameraPhase: 'establish' | 'transition' | 'hold';
  cameraZoom: number;
  cameraCenterCssX: number;
  cameraCenterCssY: number;
  cursorVisible: boolean;
  cursorInterpolation: 'hidden' | 'exact' | 'linear' | 'held';
  rgbaSha256: string;
}

export class CameraDiagnosticSink implements FrameConsumer {
  private expectedIndex = 0;
  private readonly rolling = createHash('sha256');
  private readonly landing: CursorLandingMeasurement[] = [];
  private readonly framing: TargetFramingMeasurement[] = [];
  private readonly snapshots: SnapshotRecord[] = [];
  private readonly cameraStates: CameraRawRgbaFrame['camera'][] = [];
  private readonly cursorFrames = { visible: 0, hidden: 0, exact: 0, linear: 0, held: 0 };
  private cropSafetyCorrections = 0;
  private blackEdgeFrames = 0;
  private closed = false;

  private constructor(
    private readonly outputDirectory: string,
    private readonly file: FileHandle,
    private readonly compositor: BaseFrameCompositor,
    private readonly viewport: Size,
    private readonly source: Size,
    private readonly landingEvents: ReadonlyMap<number, readonly ClickTimelineEvent[]>,
    private readonly snapshotPurposes: ReadonlyMap<number, string>,
  ) {}

  static async create(options: {
    outputDirectory: string;
    compositor: BaseFrameCompositor;
    viewport: Size;
    source: Size;
    landingEvents: ReadonlyMap<number, readonly ClickTimelineEvent[]>;
    snapshotPurposes: ReadonlyMap<number, string>;
  }): Promise<CameraDiagnosticSink> {
    await mkdir(resolve(options.outputDirectory, 'snapshots'), { recursive: true });
    const file = await open(resolve(options.outputDirectory, 'frame-hashes.jsonl'), 'wx');
    return new CameraDiagnosticSink(
      options.outputDirectory,
      file,
      options.compositor,
      options.viewport,
      options.source,
      options.landingEvents,
      options.snapshotPurposes,
    );
  }

  async consume(rawFrame: RawRgbaFrame): Promise<void> {
    const frame = rawFrame as CameraRawRgbaFrame;
    if (this.closed) throw new Error('Camera diagnostic sink is closed');
    if (frame.outputIndex !== this.expectedIndex) {
      throw new Error(`Expected camera frame ${this.expectedIndex}, received ${frame.outputIndex}`);
    }
    assertRawRgbaLayout(frame);
    this.validateCrop(frame);
    if (hasCameraGeneratedBlackEdge(frame.data, this.compositor.contentRect)) {
      this.blackEdgeFrames += 1;
    }
    const rgbaSha256 = createHash('sha256').update(frame.data).digest('hex');
    const record: CameraFrameHashRecord = {
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
      rgbaSha256,
    };
    await this.file.write(`${JSON.stringify(record)}\n`);
    this.rolling.update(frame.data);
    this.cameraStates.push(frame.camera);
    if (frame.cursor.visible) this.cursorFrames.visible += 1;
    else this.cursorFrames.hidden += 1;
    if (frame.cursor.interpolation !== 'hidden') this.cursorFrames[frame.cursor.interpolation] += 1;

    for (const click of this.landingEvents.get(frame.outputIndex) ?? []) {
      if (!frame.cursorPlacement) throw new Error(`${click.id} has no camera cursor placement`);
      if (!frame.cursorPixelsChanged || frame.cursorPixelsChanged < 1) {
        throw new Error(`${click.id} cursor raster did not change camera-composited pixels`);
      }
      const clickScreen = projectCssPoint(
        click.clickPoint,
        frame.camera,
        this.viewport,
        this.compositor.contentRect,
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
          cursorScreen: cameraCursorHotspot(frame),
          clickScreen,
        }),
      );
      this.framing.push(
        measureTargetFraming({
          click,
          outputIndex: frame.outputIndex,
          camera: frame.camera,
          viewport: this.viewport,
          contentRect: this.compositor.contentRect,
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
    if (this.closed) throw new Error('Camera diagnostic sink is already closed');
    this.closed = true;
    await this.file.close();
    return {
      frameCount: this.expectedIndex,
      rollingRgbaSha256: this.rolling.digest('hex'),
      landing: [...this.landing],
      framing: [...this.framing],
      snapshots: [...this.snapshots],
      cameraStates: [...this.cameraStates],
      cursorFrames: { ...this.cursorFrames },
      cropSafetyCorrections: this.cropSafetyCorrections,
      blackEdgeFrames: this.blackEdgeFrames,
    };
  }

  async abort(): Promise<void> {
    if (!this.closed) await this.file.close();
    this.closed = true;
  }

  private validateCrop(frame: CameraRawRgbaFrame): void {
    const epsilon = 1e-7;
    const crop = frame.sourceCrop;
    if (
      crop.x < -epsilon ||
      crop.y < -epsilon ||
      crop.x + crop.width > this.source.width + epsilon ||
      crop.y + crop.height > this.source.height + epsilon ||
      crop.width <= 0 ||
      crop.height <= 0
    ) {
      throw new Error(`Frame ${frame.outputIndex} source crop is unsafe`);
    }
    const expectedAspect = this.viewport.width / this.viewport.height;
    if (Math.abs(crop.width / crop.height - expectedAspect) > epsilon) {
      throw new Error(`Frame ${frame.outputIndex} source crop aspect ratio changed`);
    }
    if (
      crop.x < 0 ||
      crop.y < 0 ||
      crop.x + crop.width > this.source.width ||
      crop.y + crop.height > this.source.height
    ) {
      this.cropSafetyCorrections += 1;
    }
  }
}

function hasCameraGeneratedBlackEdge(
  data: Uint8Array,
  contentRect: { x: number; y: number; width: number; height: number },
): boolean {
  const edges: Array<Array<[number, number]>> = [[], [], [], []];
  for (let y = contentRect.y; y < contentRect.y + contentRect.height; y += 20) {
    edges[0]?.push([contentRect.x, y]);
    edges[1]?.push([contentRect.x + contentRect.width - 1, y]);
  }
  for (let x = contentRect.x; x < contentRect.x + contentRect.width; x += 20) {
    edges[2]?.push([x, contentRect.y]);
    edges[3]?.push([x, contentRect.y + contentRect.height - 1]);
  }
  return edges.some((edge) => {
    const black = edge.filter(([x, y]) => {
      const offset = (y * 1920 + x) * 4;
      return data[offset] === 0 && data[offset + 1] === 0 && data[offset + 2] === 0;
    }).length;
    return edge.length > 0 && black / edge.length >= 0.9;
  });
}

export async function writeCameraArtifacts(options: {
  outputDirectory: string;
  manifest: unknown;
  cameraTrack: unknown;
  landing: readonly CursorLandingMeasurement[];
  framing: readonly TargetFramingMeasurement[];
}): Promise<void> {
  const files: Array<[string, unknown]> = [
    ['manifest.json', options.manifest],
    ['camera-track.json', options.cameraTrack],
    ['landing-measurements.json', options.landing],
    ['target-framing.json', options.framing],
  ];
  for (const [file, value] of files) {
    await writeFile(resolve(options.outputDirectory, file), `${JSON.stringify(value, null, 2)}\n`, {
      flag: 'wx',
    });
  }
}
