import type { Image } from '@napi-rs/canvas';
import type { Point } from '../timeline/types.js';
import { BaseFrameCompositor } from './base-frame-compositor.js';
import type { LoadedCursorAsset } from './cursor-asset.js';
import { type CssViewport, cssPointToScreen } from './cursor-coordinate-transform.js';
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

export interface CursorRawRgbaFrame extends RawRgbaFrame {
  cursor: CursorFrameState;
  cursorPlacement?: CursorPlacement;
  cursorPixelsChanged?: number;
}

export class CursorFrameCompositor implements FrameCompositor {
  readonly base: BaseFrameCompositor;

  constructor(
    sourceWidth: number,
    sourceHeight: number,
    private readonly viewport: CssViewport,
    private readonly cursorAsset: LoadedCursorAsset,
    private readonly evaluator: SequentialCursorEvaluator,
    private readonly landingOutputIndices: ReadonlySet<number> = new Set(),
  ) {
    this.base = new BaseFrameCompositor(sourceWidth, sourceHeight);
  }

  compose(frameContext: CompositionFrameContext, image: Image): CursorRawRgbaFrame {
    const evaluated = this.evaluator.evaluate(frameContext.outputTimestampMs);
    let cursor = evaluated;
    let placement: CursorPlacement | undefined;
    let probeRect: Rect | undefined;
    let baseProbe: Uint8Array | undefined;
    const frame = this.base.composeWithOverlay(frameContext, image, (context) => {
      if (!evaluated.visible || evaluated.cssX === undefined || evaluated.cssY === undefined)
        return;
      const screen = cssPointToScreen(
        { x: evaluated.cssX, y: evaluated.cssY },
        this.viewport,
        this.base.contentRect,
      );
      cursor = { ...evaluated, screenX: screen.x, screenY: screen.y };
      placement = cursorPlacement(this.cursorAsset, screen);
      if (this.landingOutputIndices.has(frameContext.outputIndex)) {
        probeRect = placementProbeRect(placement);
        baseProbe = this.base.sampleRgba(probeRect);
      }
      drawCursor(context, this.cursorAsset, screen);
    });
    const cursorPixelsChanged =
      probeRect && baseProbe ? changedPixels(frame.data, baseProbe, probeRect) : undefined;
    return {
      ...frame,
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

export function cursorHotspot(frame: CursorRawRgbaFrame): Point {
  const placement = frame.cursorPlacement;
  if (!placement) throw new Error('Cursor frame has no rendered hotspot');
  return { x: placement.hotspotScreenX, y: placement.hotspotScreenY };
}
