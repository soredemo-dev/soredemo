import type { SKRSContext2D } from '@napi-rs/canvas';
import type { Rect } from './types.js';

export function addRoundedRectPath(context: SKRSContext2D, rect: Rect, radius: number): void {
  if (
    ![rect.x, rect.y, rect.width, rect.height, radius].every(Number.isFinite) ||
    rect.width <= 0 ||
    rect.height <= 0 ||
    radius < 0 ||
    radius > Math.min(rect.width, rect.height) / 2
  ) {
    throw new Error('Rounded rectangle geometry is invalid');
  }
  const right = rect.x + rect.width;
  const bottom = rect.y + rect.height;
  context.beginPath();
  context.moveTo(rect.x + radius, rect.y);
  context.lineTo(right - radius, rect.y);
  context.quadraticCurveTo(right, rect.y, right, rect.y + radius);
  context.lineTo(right, bottom - radius);
  context.quadraticCurveTo(right, bottom, right - radius, bottom);
  context.lineTo(rect.x + radius, bottom);
  context.quadraticCurveTo(rect.x, bottom, rect.x, bottom - radius);
  context.lineTo(rect.x, rect.y + radius);
  context.quadraticCurveTo(rect.x, rect.y, rect.x + radius, rect.y);
  context.closePath();
}
