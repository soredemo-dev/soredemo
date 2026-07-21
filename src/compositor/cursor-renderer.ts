import type { SKRSContext2D } from '@napi-rs/canvas';
import type { Point } from '../timeline/types.js';
import type { LoadedCursorAsset } from './cursor-asset.js';

export interface CursorPlacement {
  hotspotScreenX: number;
  hotspotScreenY: number;
  drawX: number;
  drawY: number;
  width: number;
  height: number;
}

export function cursorPlacement(asset: LoadedCursorAsset, hotspot: Point): CursorPlacement {
  if (!Number.isFinite(hotspot.x) || !Number.isFinite(hotspot.y)) {
    throw new Error('Cursor screen hotspot must be finite');
  }
  const definition = asset.definition;
  const renderedHotspotX =
    (definition.hotspotX * definition.renderedWidth) / definition.sourceWidth;
  const renderedHotspotY =
    (definition.hotspotY * definition.renderedHeight) / definition.sourceHeight;
  return {
    hotspotScreenX: hotspot.x,
    hotspotScreenY: hotspot.y,
    drawX: hotspot.x - renderedHotspotX,
    drawY: hotspot.y - renderedHotspotY,
    width: definition.renderedWidth,
    height: definition.renderedHeight,
  };
}

export function drawCursor(
  context: SKRSContext2D,
  asset: LoadedCursorAsset,
  hotspot: Point,
): CursorPlacement {
  const placement = cursorPlacement(asset, hotspot);
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = 'high';
  // The browser layer may be transformed later; the cursor stays fixed in output-screen space.
  context.drawImage(
    asset.image,
    placement.drawX,
    placement.drawY,
    placement.width,
    placement.height,
  );
  return placement;
}
