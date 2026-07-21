import { type Canvas, createCanvas, type Image } from '@napi-rs/canvas';
import type { Point } from '../timeline/types.js';
import type { SequentialCameraEvaluator } from './camera-evaluator.js';
import { projectCssPoint, sourceCropForCamera } from './camera-projection.js';
import type { CameraFrameState, Size, SourceCrop } from './camera-types.js';
import { drawClickFeedback, type RenderedClickRipple } from './click-feedback-renderer.js';
import type { SequentialClickFeedbackEvaluator } from './click-feedback-track.js';
import type { LoadedCursorAsset } from './cursor-asset.js';
import { type CursorPlacement, cursorPlacement, drawCursor } from './cursor-renderer.js';
import type { CursorFrameState, SequentialCursorEvaluator } from './cursor-track.js';
import { drawStudioGradient } from './gradient-background.js';
import { drawMacosToolbar } from './macos-toolbar.js';
import { rgbaBytes } from './rgba.js';
import { addRoundedRectPath } from './rounded-rect.js';
import {
  STUDIO_BROWSER_CONTENT_RECT,
  STUDIO_BROWSER_WINDOW_RECT,
  STUDIO_LOCAL_CONTENT_RECT,
  STUDIO_LOCAL_WINDOW_RECT,
  STUDIO_WINDOW_RADIUS,
} from './studio-layout.js';
import {
  type CompositionFrameContext,
  type FrameCompositor,
  OUTPUT_HEIGHT,
  OUTPUT_WIDTH,
  type RawRgbaFrame,
  type Rect,
  RGBA_BYTE_LENGTH,
  RGBA_STRIDE_BYTES,
} from './types.js';
import {
  createStudioWindowShadowLayer,
  drawStudioWindowBorder,
  STUDIO_SHADOW_LAYER_RECT,
} from './window-shadow.js';

export interface StudioRawRgbaFrame extends RawRgbaFrame {
  camera: CameraFrameState;
  sourceCrop: SourceCrop;
  cursor: CursorFrameState;
  cursorPlacement?: CursorPlacement;
  cursorPixelsChanged?: number;
  ripples: RenderedClickRipple[];
}

export class StudioFrameCompositor implements FrameCompositor {
  readonly contentRect = STUDIO_BROWSER_CONTENT_RECT;
  private readonly outputCanvas: Canvas;
  private readonly outputContext;
  private readonly windowCanvas: Canvas;
  private readonly windowContext;
  private readonly shadowCanvas: Canvas;
  private readonly source: Size;

  constructor(
    sourceWidth: number,
    sourceHeight: number,
    private readonly viewport: Size,
    private readonly cursorAsset: LoadedCursorAsset,
    private readonly cameraEvaluator: SequentialCameraEvaluator,
    private readonly cursorEvaluator: SequentialCursorEvaluator,
    private readonly clickFeedbackEvaluator: SequentialClickFeedbackEvaluator,
    private readonly landingOutputIndices: ReadonlySet<number> = new Set(),
  ) {
    this.source = { width: sourceWidth, height: sourceHeight };
    this.outputCanvas = createCanvas(OUTPUT_WIDTH, OUTPUT_HEIGHT);
    this.outputContext = this.outputCanvas.getContext('2d');
    this.windowCanvas = createCanvas(
      STUDIO_LOCAL_WINDOW_RECT.width,
      STUDIO_LOCAL_WINDOW_RECT.height,
    );
    this.shadowCanvas = createStudioWindowShadowLayer();
    this.windowContext = this.windowCanvas.getContext('2d');
    this.outputContext.imageSmoothingEnabled = true;
    this.outputContext.imageSmoothingQuality = 'high';
    this.windowContext.imageSmoothingEnabled = true;
    this.windowContext.imageSmoothingQuality = 'high';
  }

  compose(frameContext: CompositionFrameContext, image: Image): StudioRawRgbaFrame {
    if (image.width !== this.source.width || image.height !== this.source.height) {
      throw new Error('Source image dimensions changed during studio composition');
    }
    const camera = this.cameraEvaluator.evaluate(frameContext.outputTimestampMs);
    const sourceCrop = sourceCropForCamera(camera, this.viewport, this.source);
    const cursorState = this.cursorEvaluator.evaluate(frameContext.outputTimestampMs);
    const rippleStates = this.clickFeedbackEvaluator.evaluate(frameContext.outputTimestampMs);
    this.drawWindow(image, sourceCrop);
    drawStudioGradient(this.outputContext);
    this.outputContext.drawImage(
      this.shadowCanvas,
      STUDIO_SHADOW_LAYER_RECT.x,
      STUDIO_SHADOW_LAYER_RECT.y,
    );
    this.outputContext.drawImage(
      this.windowCanvas,
      STUDIO_BROWSER_WINDOW_RECT.x,
      STUDIO_BROWSER_WINDOW_RECT.y,
    );
    drawStudioWindowBorder(this.outputContext);
    const ripples = drawClickFeedback(
      this.outputContext,
      rippleStates,
      camera,
      this.viewport,
      STUDIO_BROWSER_CONTENT_RECT,
    );

    let cursor = cursorState;
    let placement: CursorPlacement | undefined;
    let probeRect: Rect | undefined;
    let baseProbe: Uint8Array | undefined;
    if (cursorState.visible && cursorState.cssX !== undefined && cursorState.cssY !== undefined) {
      const screen = projectCssPoint(
        { x: cursorState.cssX, y: cursorState.cssY },
        camera,
        this.viewport,
        STUDIO_BROWSER_CONTENT_RECT,
      );
      cursor = { ...cursorState, screenX: screen.x, screenY: screen.y };
      // Camera projection moves browser-space coordinates; cursor raster dimensions remain screen-space.
      placement = cursorPlacement(this.cursorAsset, screen);
      if (this.landingOutputIndices.has(frameContext.outputIndex)) {
        probeRect = placementProbeRect(placement);
        baseProbe = this.sampleRgba(probeRect);
      }
      drawCursor(this.outputContext, this.cursorAsset, screen);
    }
    const data = rgbaBytes(this.outputCanvas.data());
    if (data.byteLength !== RGBA_BYTE_LENGTH) {
      throw new Error('Studio canvas returned unexpected RGBA size');
    }
    const cursorPixelsChanged =
      probeRect && baseProbe ? changedPixels(data, baseProbe, probeRect) : undefined;
    return {
      outputIndex: frameContext.outputIndex,
      outputTimestampMs: frameContext.outputTimestampMs,
      sourceIndex: frameContext.sourceIndex,
      sourceTimestampMs: frameContext.sourceTimestampMs,
      width: OUTPUT_WIDTH,
      height: OUTPUT_HEIGHT,
      strideBytes: RGBA_STRIDE_BYTES,
      byteLength: RGBA_BYTE_LENGTH,
      data,
      camera,
      sourceCrop,
      cursor,
      ...(placement ? { cursorPlacement: placement } : {}),
      ...(cursorPixelsChanged === undefined ? {} : { cursorPixelsChanged }),
      ripples,
    };
  }

  png(): Buffer {
    return this.outputCanvas.toBuffer('image/png');
  }

  cropPng(rect: Rect): Buffer {
    const crop = integerCrop(rect);
    const canvas = createCanvas(crop.width, crop.height);
    canvas
      .getContext('2d')
      .drawImage(
        this.outputCanvas,
        crop.x,
        crop.y,
        crop.width,
        crop.height,
        0,
        0,
        crop.width,
        crop.height,
      );
    return canvas.toBuffer('image/png');
  }

  private drawWindow(image: Image, sourceCrop: SourceCrop): void {
    this.windowContext.clearRect(
      0,
      0,
      STUDIO_LOCAL_WINDOW_RECT.width,
      STUDIO_LOCAL_WINDOW_RECT.height,
    );
    this.windowContext.save();
    addRoundedRectPath(this.windowContext, STUDIO_LOCAL_WINDOW_RECT, STUDIO_WINDOW_RADIUS);
    this.windowContext.clip();
    drawMacosToolbar(this.windowContext);
    this.windowContext.drawImage(
      image,
      sourceCrop.x,
      sourceCrop.y,
      sourceCrop.width,
      sourceCrop.height,
      STUDIO_LOCAL_CONTENT_RECT.x,
      STUDIO_LOCAL_CONTENT_RECT.y,
      STUDIO_LOCAL_CONTENT_RECT.width,
      STUDIO_LOCAL_CONTENT_RECT.height,
    );
    this.windowContext.restore();
  }

  private sampleRgba(rect: Rect): Uint8Array {
    const { x, y, width, height } = integerCrop(rect);
    const sample = createCanvas(width, height);
    sample.getContext('2d').drawImage(this.outputCanvas, x, y, width, height, 0, 0, width, height);
    return rgbaBytes(sample.data());
  }
}

function placementProbeRect(placement: CursorPlacement): Rect {
  const margin = 3;
  const left = Math.max(0, Math.floor(placement.drawX) - margin);
  const top = Math.max(0, Math.floor(placement.drawY) - margin);
  const right = Math.min(OUTPUT_WIDTH, Math.ceil(placement.drawX + placement.width) + margin);
  const bottom = Math.min(OUTPUT_HEIGHT, Math.ceil(placement.drawY + placement.height) + margin);
  return { x: left, y: top, width: right - left, height: bottom - top };
}

function changedPixels(frame: Uint8Array, baseline: Uint8Array, rect: Rect): number {
  let changed = 0;
  for (let y = 0; y < rect.height; y += 1) {
    for (let x = 0; x < rect.width; x += 1) {
      const frameOffset = ((rect.y + y) * OUTPUT_WIDTH + rect.x + x) * 4;
      const baselineOffset = (y * rect.width + x) * 4;
      if (
        frame[frameOffset] !== baseline[baselineOffset] ||
        frame[frameOffset + 1] !== baseline[baselineOffset + 1] ||
        frame[frameOffset + 2] !== baseline[baselineOffset + 2]
      ) {
        changed += 1;
      }
    }
  }
  return changed;
}

function integerCrop(rect: Rect): Rect {
  if (
    !Number.isInteger(rect.x) ||
    !Number.isInteger(rect.y) ||
    !Number.isInteger(rect.width) ||
    !Number.isInteger(rect.height) ||
    rect.x < 0 ||
    rect.y < 0 ||
    rect.width < 1 ||
    rect.height < 1 ||
    rect.x + rect.width > OUTPUT_WIDTH ||
    rect.y + rect.height > OUTPUT_HEIGHT
  ) {
    throw new Error('Studio sample must be an integer rectangle inside output bounds');
  }
  return rect;
}

export function studioCursorHotspot(frame: StudioRawRgbaFrame): Point {
  const placement = frame.cursorPlacement;
  if (!placement) throw new Error('Studio frame has no rendered cursor hotspot');
  return { x: placement.hotspotScreenX, y: placement.hotspotScreenY };
}
