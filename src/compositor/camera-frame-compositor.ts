import type { Image } from '@napi-rs/canvas';
import type { Point } from '../timeline/types.js';
import { BaseFrameCompositor } from './base-frame-compositor.js';
import { projectCssPoint, sourceCropForCamera } from './camera-projection.js';
import type { CameraFrameState, Size, SourceCrop } from './camera-types.js';
import type { SequentialCameraEvaluator } from './camera-evaluator.js';
import type { LoadedCursorAsset } from './cursor-asset.js';
import { type CursorPlacement, cursorPlacement, drawCursor } from './cursor-renderer.js';
import type { CursorFrameState, SequentialCursorEvaluator } from './cursor-track.js';
import {
  type CompositionFrameContext,
  type FrameCompositor,
  OUTPUT_HEIGHT,
  OUTPUT_WIDTH,
  type RawRgbaFrame,
  type Rect,
} from './types.js';

export interface CameraRawRgbaFrame extends RawRgbaFrame {
  camera: CameraFrameState;
  sourceCrop: SourceCrop;
  cursor: CursorFrameState;
  cursorPlacement?: CursorPlacement;
  cursorPixelsChanged?: number;
}

export class CameraFrameCompositor implements FrameCompositor {
  readonly base: BaseFrameCompositor;
  private readonly source: Size;

  constructor(
    sourceWidth: number,
    sourceHeight: number,
    private readonly viewport: Size,
    private readonly cursorAsset: LoadedCursorAsset,
    private readonly cameraEvaluator: SequentialCameraEvaluator,
    private readonly cursorEvaluator: SequentialCursorEvaluator,
    private readonly landingOutputIndices: ReadonlySet<number> = new Set(),
  ) {
    this.source = { width: sourceWidth, height: sourceHeight };
    this.base = new BaseFrameCompositor(sourceWidth, sourceHeight);
  }

  compose(frameContext: CompositionFrameContext, image: Image): CameraRawRgbaFrame {
    const camera = this.cameraEvaluator.evaluate(frameContext.outputTimestampMs);
    const sourceCrop = sourceCropForCamera(camera, this.viewport, this.source);
    const evaluated = this.cursorEvaluator.evaluate(frameContext.outputTimestampMs);
    let cursor = evaluated;
    let placement: CursorPlacement | undefined;
    let probeRect: Rect | undefined;
    let baseProbe: Uint8Array | undefined;
    const frame = this.base.composeSourceCropWithOverlay(
      frameContext,
      image,
      sourceCrop,
      (context) => {
        if (!evaluated.visible || evaluated.cssX === undefined || evaluated.cssY === undefined)
          return;
        const screen = projectCssPoint(
          { x: evaluated.cssX, y: evaluated.cssY },
          camera,
          this.viewport,
          this.base.contentRect,
        );
        cursor = { ...evaluated, screenX: screen.x, screenY: screen.y };
        // Camera projection moves browser-space coordinates; cursor raster dimensions remain screen-space.
        placement = cursorPlacement(this.cursorAsset, screen);
        if (this.landingOutputIndices.has(frameContext.outputIndex)) {
          probeRect = placementProbeRect(placement);
          baseProbe = this.base.sampleRgba(probeRect);
        }
        drawCursor(context, this.cursorAsset, screen);
      },
    );
    const cursorPixelsChanged =
      probeRect && baseProbe ? changedPixels(frame.data, baseProbe, probeRect) : undefined;
    return {
      ...frame,
      camera,
      sourceCrop,
      cursor,
      ...(placement ? { cursorPlacement: placement } : {}),
      ...(cursorPixelsChanged === undefined ? {} : { cursorPixelsChanged }),
    };
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

export function cameraCursorHotspot(frame: CameraRawRgbaFrame): Point {
  const placement = frame.cursorPlacement;
  if (!placement) throw new Error('Camera frame has no rendered cursor hotspot');
  return { x: placement.hotspotScreenX, y: placement.hotspotScreenY };
}
