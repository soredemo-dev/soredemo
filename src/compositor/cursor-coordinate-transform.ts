import type { Point } from '../timeline/types.js';
import type { Rect } from './types.js';

export interface CssViewport {
  width: number;
  height: number;
}

export function cssPointToScreen(point: Point, viewport: CssViewport, contentRect: Rect): Point {
  if (
    !Number.isFinite(point.x) ||
    !Number.isFinite(point.y) ||
    point.x < 0 ||
    point.y < 0 ||
    point.x > viewport.width ||
    point.y > viewport.height
  ) {
    throw new Error('Cursor CSS point must be finite and inside the viewport');
  }
  if (
    !Number.isFinite(viewport.width) ||
    !Number.isFinite(viewport.height) ||
    viewport.width <= 0 ||
    viewport.height <= 0 ||
    !Number.isFinite(contentRect.x) ||
    !Number.isFinite(contentRect.y) ||
    contentRect.width <= 0 ||
    contentRect.height <= 0
  ) {
    throw new Error('Cursor coordinate transform geometry is invalid');
  }
  return {
    x: contentRect.x + (point.x * contentRect.width) / viewport.width,
    y: contentRect.y + (point.y * contentRect.height) / viewport.height,
  };
}
