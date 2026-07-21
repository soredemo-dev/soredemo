import { createHash } from 'node:crypto';
import type { FileHandle } from 'node:fs/promises';
import { mkdir, open, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import {
  cursorActionLandingStatistics,
  cursorFrameSample,
  isCursorBearingEvent,
  measureCursorActionLanding,
  type CursorActionFrameRequest,
  type CursorActionFrameSample,
  type CursorActionLandingMeasurement,
  type CursorActionLandingStatistics,
  type CursorBearingTimelineEvent,
} from '../compositor/cursor-action-landing.js';
import { projectCssPoint, projectCssRect } from '../compositor/camera-projection.js';
import type { StudioFrameCompositor, StudioRawRgbaFrame } from '../compositor/studio-frame-compositor.js';
import { STUDIO_BROWSER_CONTENT_RECT } from '../compositor/studio-layout.js';
import type { FrameConsumer, RawRgbaFrame, Rect } from '../compositor/types.js';
import type { ResampledFrameRecord } from '../resample/types.js';
import type { Point, TimelineEvent } from '../timeline/types.js';

export interface CursorProofFrameRecord extends CursorActionFrameSample {
  sourceIndex: number;
  sourceTimestampMs: number;
  camera: StudioRawRgbaFrame['camera'];
  visibleCssCrop: Rect;
  sourceCrop: Rect;
  targetBboxCss: Rect;
  projectedTargetBbox: Rect;
  cursorDrawOrigin: Point;
  cursorRenderedSize: { width: number; height: number };
  cursorRenderedHotspot: Point;
  cropRect: Rect;
  file: string;
  pngSha256: string;
  targetPixelEvidence: {
    sampledPixels: number;
    rgbStandardDeviation: number;
    nonUniformFraction: number;
  };
}

export interface CursorActionAuditResult {
  frameCount: number;
  rollingRgbaSha256: string;
  measurements: CursorActionLandingMeasurement[];
  statistics: CursorActionLandingStatistics;
  samples: CursorActionFrameSample[];
  proofs: CursorProofFrameRecord[];
}

interface LandingFrameContext {
  event: CursorBearingTimelineEvent;
  frame: ResampledFrameRecord;
  camera: StudioRawRgbaFrame['camera'];
  cursor: StudioRawRgbaFrame['cursor'];
  cursorPlacement: NonNullable<StudioRawRgbaFrame['cursorPlacement']>;
  cursorPixelsChanged: number;
}

export class CursorActionAuditConsumer implements FrameConsumer {
  private expectedIndex = 0;
  private readonly rolling = createHash('sha256');
  private readonly requestsByFrame = new Map<number, CursorActionFrameRequest[]>();
  private readonly samples: CursorActionFrameSample[] = [];
  private readonly proofs: CursorProofFrameRecord[] = [];
  private readonly landingFrames = new Map<string, LandingFrameContext>();
  private closed = false;

  private constructor(
    private readonly outputDirectory: string,
    private readonly hashes: FileHandle,
    private readonly compositor: StudioFrameCompositor,
    private readonly viewport: { width: number; height: number },
    private readonly events: readonly TimelineEvent[],
    requests: readonly CursorActionFrameRequest[],
    private readonly delegate: FrameConsumer,
  ) {
    for (const request of requests) {
      const atFrame = this.requestsByFrame.get(request.outputIndex) ?? [];
      atFrame.push(request);
      this.requestsByFrame.set(request.outputIndex, atFrame);
    }
  }

  static async create(options: {
    outputDirectory: string;
    compositor: StudioFrameCompositor;
    viewport: { width: number; height: number };
    events: readonly TimelineEvent[];
    requests: readonly CursorActionFrameRequest[];
    delegate: FrameConsumer;
  }): Promise<CursorActionAuditConsumer> {
    await mkdir(resolve(options.outputDirectory, 'crops', 'rgba'), { recursive: true });
    const hashes = await open(resolve(options.outputDirectory, 'frame-hashes.jsonl'), 'wx');
    return new CursorActionAuditConsumer(
      options.outputDirectory,
      hashes,
      options.compositor,
      options.viewport,
      options.events,
      options.requests,
      options.delegate,
    );
  }

  async consume(rawFrame: RawRgbaFrame): Promise<void> {
    if (this.closed) throw new Error('Cursor action audit is closed');
    if (rawFrame.outputIndex !== this.expectedIndex) {
      throw new Error(`Cursor action audit expected frame ${this.expectedIndex}`);
    }
    const frame = rawFrame as StudioRawRgbaFrame;
    const rgbaSha256 = createHash('sha256').update(frame.data).digest('hex');
    await this.hashes.write(
      `${JSON.stringify({
        outputIndex: frame.outputIndex,
        outputTimestampMs: frame.outputTimestampMs,
        sourceIndex: frame.sourceIndex,
        sourceTimestampMs: frame.sourceTimestampMs,
        cameraSegmentId: frame.camera.segmentId,
        cameraZoom: frame.camera.zoom,
        cursorVisible: frame.cursor.visible,
        cursorInterpolation: frame.cursor.interpolation,
        rgbaSha256,
      })}\n`,
    );
    this.rolling.update(frame.data);
    for (const request of this.requestsByFrame.get(frame.outputIndex) ?? []) {
      await this.captureProof(request, frame);
    }
    await this.delegate.consume(frame);
    this.expectedIndex += 1;
  }

  async finish(): Promise<CursorActionAuditResult> {
    if (this.closed) throw new Error('Cursor action audit is already closed');
    this.closed = true;
    await this.hashes.close();
    const measurements = this.events.filter(isCursorBearingEvent).map((event) => {
      const context = this.landingFrames.get(event.id);
      if (!context) throw new Error(`${event.id} has no composed landing frame`);
      return measureCursorActionLanding({
        event,
        frame: context.frame,
        camera: context.camera,
        cursor: context.cursor,
        cursorPlacement: context.cursorPlacement,
        cursorPixelsChanged: context.cursorPixelsChanged,
        viewport: this.viewport,
        contentRect: STUDIO_BROWSER_CONTENT_RECT,
        samples: this.samples,
      });
    });
    const statistics = cursorActionLandingStatistics(measurements);
    const result = {
      frameCount: this.expectedIndex,
      rollingRgbaSha256: this.rolling.digest('hex'),
      measurements,
      statistics,
      samples: [...this.samples],
      proofs: [...this.proofs],
    };
    await Promise.all([
      writeFile(
        resolve(this.outputDirectory, 'cursor-action-landings.json'),
        `${JSON.stringify({ measurements, statistics }, null, 2)}\n`,
      ),
      writeFile(
        resolve(this.outputDirectory, 'cursor-proof-frames.json'),
        `${JSON.stringify({ samples: this.samples, proofs: this.proofs }, null, 2)}\n`,
      ),
    ]);
    return result;
  }

  async abort(): Promise<void> {
    if (!this.closed) await this.hashes.close();
    this.closed = true;
  }

  private async captureProof(
    request: CursorActionFrameRequest,
    frame: StudioRawRgbaFrame,
  ): Promise<void> {
    const placement = frame.cursorPlacement;
    if (!placement) throw new Error(`${request.event.id} has no rendered cursor placement`);
    const mappedFrame = resampledFrame(frame);
    const sample = cursorFrameSample({
      request,
      frame: mappedFrame,
      cursor: frame.cursor,
      cursorPlacement: placement,
      camera: frame.camera,
      viewport: this.viewport,
      contentRect: STUDIO_BROWSER_CONTENT_RECT,
    });
    this.samples.push(sample);
    const targetBboxCss = request.event.targetBboxAtCommit;
    const projectedTargetBbox = projectCssRect(
      targetBboxCss,
      frame.camera,
      this.viewport,
      STUDIO_BROWSER_CONTENT_RECT,
    );
    const expectedScreen = projectCssPoint(
      expectedPoint(request.event),
      frame.camera,
      this.viewport,
      STUDIO_BROWSER_CONTENT_RECT,
    );
    const cropRect = centeredCrop(expectedScreen, 256, 256);
    const png = this.compositor.cropPng(cropRect);
    const file = `crops/rgba/${request.event.id}-${request.role}-frame-${String(frame.outputIndex).padStart(6, '0')}.png`;
    await writeFile(resolve(this.outputDirectory, file), png, { flag: 'wx' });
    this.proofs.push({
      ...sample,
      sourceIndex: frame.sourceIndex,
      sourceTimestampMs: frame.sourceTimestampMs,
      camera: frame.camera,
      visibleCssCrop: frame.camera.visibleCssRect,
      sourceCrop: frame.sourceCrop,
      targetBboxCss,
      projectedTargetBbox,
      cursorDrawOrigin: { x: placement.drawX, y: placement.drawY },
      cursorRenderedSize: { width: placement.width, height: placement.height },
      cursorRenderedHotspot: {
        x: placement.hotspotScreenX - placement.drawX,
        y: placement.hotspotScreenY - placement.drawY,
      },
      cropRect,
      file,
      pngSha256: createHash('sha256').update(png).digest('hex'),
      targetPixelEvidence: targetPixelEvidence(frame, projectedTargetBbox, placement),
    });
    if (isLandingRole(request.event, request.role)) {
      if (frame.cursorPixelsChanged === undefined || frame.cursorPixelsChanged < 1) {
        throw new Error(`${request.event.id} cursor did not alter its composed landing frame`);
      }
      this.landingFrames.set(request.event.id, {
        event: request.event,
        frame: mappedFrame,
        camera: frame.camera,
        cursor: frame.cursor,
        cursorPlacement: placement,
        cursorPixelsChanged: frame.cursorPixelsChanged,
      });
    }
  }
}

function isLandingRole(event: CursorBearingTimelineEvent, role: CursorActionFrameRequest['role']) {
  return event.kind === 'click' ? role === 'mouse-down' : role === 'path-completion';
}

function expectedPoint(event: CursorBearingTimelineEvent): Point {
  if (event.kind === 'moveTo') return event.destinationPoint;
  if (event.kind === 'click') return event.clickPoint;
  return event.focusPoint;
}

function resampledFrame(frame: StudioRawRgbaFrame): ResampledFrameRecord {
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

function centeredCrop(point: Point, width: number, height: number): Rect {
  const x = Math.max(0, Math.min(1920 - width, Math.round(point.x - width / 2)));
  const y = Math.max(0, Math.min(1080 - height, Math.round(point.y - height / 2)));
  return { x, y, width, height };
}

function targetPixelEvidence(
  frame: StudioRawRgbaFrame,
  target: Rect,
  cursor: NonNullable<StudioRawRgbaFrame['cursorPlacement']>,
): CursorProofFrameRecord['targetPixelEvidence'] {
  const left = Math.max(0, Math.ceil(target.x));
  const top = Math.max(0, Math.ceil(target.y));
  const right = Math.min(frame.width, Math.floor(target.x + target.width));
  const bottom = Math.min(frame.height, Math.floor(target.y + target.height));
  const cursorLeft = Math.floor(cursor.drawX) - 2;
  const cursorTop = Math.floor(cursor.drawY) - 2;
  const cursorRight = Math.ceil(cursor.drawX + cursor.width) + 2;
  const cursorBottom = Math.ceil(cursor.drawY + cursor.height) + 2;
  const values: number[] = [];
  const colors = new Map<number, number>();
  for (let y = top; y < bottom; y += 1) {
    for (let x = left; x < right; x += 1) {
      if (x >= cursorLeft && x < cursorRight && y >= cursorTop && y < cursorBottom) continue;
      const offset = (y * frame.width + x) * 4;
      const red = frame.data[offset] ?? 0;
      const green = frame.data[offset + 1] ?? 0;
      const blue = frame.data[offset + 2] ?? 0;
      values.push((red + green + blue) / 3);
      const quantized = ((red >> 3) << 10) | ((green >> 3) << 5) | (blue >> 3);
      colors.set(quantized, (colors.get(quantized) ?? 0) + 1);
    }
  }
  if (values.length === 0) {
    return { sampledPixels: 0, rgbStandardDeviation: 0, nonUniformFraction: 0 };
  }
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  const variance =
    values.reduce((sum, value) => sum + (value - mean) ** 2, 0) / values.length;
  const dominant = Math.max(...colors.values());
  return {
    sampledPixels: values.length,
    rgbStandardDeviation: Math.sqrt(variance),
    nonUniformFraction: 1 - dominant / values.length,
  };
}
