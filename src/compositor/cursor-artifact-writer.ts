import { createHash } from 'node:crypto';
import type { FileHandle } from 'node:fs/promises';
import { mkdir, open, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { ClickTimelineEvent } from '../timeline/types.js';
import type { BaseFrameCompositor } from './base-frame-compositor.js';
import { type CssViewport, cssPointToScreen } from './cursor-coordinate-transform.js';
import { type CursorRawRgbaFrame, cursorHotspot } from './cursor-frame-compositor.js';
import type { CursorInterpolation } from './cursor-track.js';
import {
  type CursorLandingMeasurement,
  type CursorLandingStatistics,
  measureCursorLanding,
} from './landing-statistics.js';
import { assertRawRgbaLayout } from './rgba.js';
import type { FrameConsumer, RawRgbaFrame, Rect, SnapshotRecord } from './types.js';

export interface CursorComposedFrameHashRecord {
  outputIndex: number;
  outputTimestampMs: number;
  sourceIndex: number;
  sourceTimestampMs: number;
  cursorVisible: boolean;
  cursorInterpolation: CursorInterpolation;
  rgbaSha256: string;
}

export interface CursorCompositionManifest {
  schemaVersion: 1;
  sourceCapturePath: string;
  sourceResamplePlanPath: string;
  sourceTimelinePath: string;
  outputWidth: 1920;
  outputHeight: 1080;
  outputFps: 30;
  outputFrameCount: number;
  cssViewport: { width: 1440; height: 900 };
  contentRect: Rect;
  cursor: {
    assetFile: string;
    assetSha256: string;
    sourceWidth: number;
    sourceHeight: number;
    hotspotX: number;
    hotspotY: number;
    renderedWidth: number;
    renderedHeight: number;
    coordinateSpace: 'output-screen';
  };
  cursorTrack: {
    clickEvents: number;
    pathPoints: number;
    firstPointMs: number;
    lastPointMs: number;
  };
  cursorFrames: {
    visible: number;
    hidden: number;
    exact: number;
    linear: number;
    held: number;
  };
  landing: CursorLandingStatistics;
  decoding: {
    decodeCount: number;
    cacheHits: number;
    cacheMisses: number;
    maxDecodedImagesRetained: number;
  };
  bytesProcessed: number;
  rollingRgbaSha256: string;
  performance: {
    executionMs: number;
    framesPerSecond: number;
    rssBeforeBytes: number;
    rssAfterBytes: number;
    peakRssBytes: number;
    rssSlopeBytesPerFrame: number;
  };
  snapshots: SnapshotRecord[];
}

export class CursorDiagnosticSink implements FrameConsumer {
  private expectedIndex = 0;
  private readonly rolling = createHash('sha256');
  private readonly measurements: CursorLandingMeasurement[] = [];
  private readonly snapshots: SnapshotRecord[] = [];
  private readonly cursorFrames = { visible: 0, hidden: 0, exact: 0, linear: 0, held: 0 };
  private closed = false;

  private constructor(
    private readonly outputDirectory: string,
    private readonly file: FileHandle,
    private readonly compositor: BaseFrameCompositor,
    private readonly viewport: CssViewport,
    private readonly landingEvents: ReadonlyMap<number, readonly ClickTimelineEvent[]>,
    private readonly fullSnapshots: ReadonlyMap<number, string>,
  ) {}

  static async create(options: {
    outputDirectory: string;
    compositor: BaseFrameCompositor;
    viewport: CssViewport;
    landingEvents: ReadonlyMap<number, readonly ClickTimelineEvent[]>;
    fullSnapshots: ReadonlyMap<number, string>;
  }): Promise<CursorDiagnosticSink> {
    await mkdir(resolve(options.outputDirectory, 'snapshots'), { recursive: true });
    const file = await open(resolve(options.outputDirectory, 'frame-hashes.jsonl'), 'wx');
    return new CursorDiagnosticSink(
      options.outputDirectory,
      file,
      options.compositor,
      options.viewport,
      options.landingEvents,
      options.fullSnapshots,
    );
  }

  async consume(rawFrame: RawRgbaFrame): Promise<void> {
    const frame = rawFrame as CursorRawRgbaFrame;
    if (this.closed) throw new Error('Cursor diagnostic sink is closed');
    if (frame.outputIndex !== this.expectedIndex) {
      throw new Error(`Expected cursor frame ${this.expectedIndex}, received ${frame.outputIndex}`);
    }
    if (!frame.cursor) throw new Error('Composed frame is missing cursor state');
    assertRawRgbaLayout(frame);
    const rgbaSha256 = createHash('sha256').update(frame.data).digest('hex');
    const record: CursorComposedFrameHashRecord = {
      outputIndex: frame.outputIndex,
      outputTimestampMs: frame.outputTimestampMs,
      sourceIndex: frame.sourceIndex,
      sourceTimestampMs: frame.sourceTimestampMs,
      cursorVisible: frame.cursor.visible,
      cursorInterpolation: frame.cursor.interpolation,
      rgbaSha256,
    };
    await this.file.write(`${JSON.stringify(record)}\n`);
    this.rolling.update(frame.data);
    if (frame.cursor.visible) this.cursorFrames.visible += 1;
    else this.cursorFrames.hidden += 1;
    if (frame.cursor.interpolation !== 'hidden') {
      this.cursorFrames[frame.cursor.interpolation] += 1;
    }

    for (const click of this.landingEvents.get(frame.outputIndex) ?? []) {
      if (!frame.cursorPlacement) throw new Error(`${click.id} has no actual cursor placement`);
      if (!frame.cursorPixelsChanged || frame.cursorPixelsChanged < 1) {
        throw new Error(`${click.id} cursor raster did not change its landing-frame pixels`);
      }
      const clickScreen = cssPointToScreen(
        click.clickPoint,
        this.viewport,
        this.compositor.contentRect,
      );
      this.measurements.push(
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
          cursorScreen: cursorHotspot(frame),
          clickScreen,
        }),
      );
      await this.writeSnapshot(
        frame,
        `${click.id} landing crop`,
        `snapshots/${click.id}.png`,
        this.compositor.cropPng(centeredCrop(clickScreen, 256)),
      );
    }

    const purpose = this.fullSnapshots.get(frame.outputIndex);
    if (purpose) {
      await this.writeSnapshot(
        frame,
        purpose,
        `snapshots/frame-${String(frame.outputIndex).padStart(6, '0')}.png`,
        this.compositor.png(),
      );
    }
    this.expectedIndex += 1;
  }

  async finish(): Promise<{
    frameCount: number;
    rollingRgbaSha256: string;
    measurements: CursorLandingMeasurement[];
    snapshots: SnapshotRecord[];
    cursorFrames: { visible: number; hidden: number; exact: number; linear: number; held: number };
  }> {
    if (this.closed) throw new Error('Cursor diagnostic sink is already closed');
    this.closed = true;
    await this.file.close();
    return {
      frameCount: this.expectedIndex,
      rollingRgbaSha256: this.rolling.digest('hex'),
      measurements: [...this.measurements],
      snapshots: [...this.snapshots],
      cursorFrames: { ...this.cursorFrames },
    };
  }

  async abort(): Promise<void> {
    if (!this.closed) await this.file.close();
    this.closed = true;
  }

  private async writeSnapshot(
    frame: CursorRawRgbaFrame,
    purpose: string,
    file: string,
    png: Buffer,
  ): Promise<void> {
    const pngSha256 = createHash('sha256').update(png).digest('hex');
    await writeFile(resolve(this.outputDirectory, file), png, { flag: 'wx' });
    this.snapshots.push({
      purpose,
      outputIndex: frame.outputIndex,
      outputTimestampMs: frame.outputTimestampMs,
      sourceIndex: frame.sourceIndex,
      sourceTimestampMs: frame.sourceTimestampMs,
      file,
      pngSha256,
    });
  }
}

function centeredCrop(point: { x: number; y: number }, size: number): Rect {
  const x = Math.max(0, Math.min(1920 - size, Math.floor(point.x - size / 2)));
  const y = Math.max(0, Math.min(1080 - size, Math.floor(point.y - size / 2)));
  return { x, y, width: size, height: size };
}

export async function writeCursorCompositionArtifacts(options: {
  outputDirectory: string;
  manifest: CursorCompositionManifest;
  measurements: readonly CursorLandingMeasurement[];
}): Promise<void> {
  await writeFile(
    resolve(options.outputDirectory, 'landing-measurements.json'),
    `${JSON.stringify(options.measurements, null, 2)}\n`,
    { flag: 'wx' },
  );
  await writeFile(
    resolve(options.outputDirectory, 'manifest.json'),
    `${JSON.stringify(options.manifest, null, 2)}\n`,
    { flag: 'wx' },
  );
}
