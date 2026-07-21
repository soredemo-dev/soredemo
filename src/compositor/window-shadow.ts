import type { SKRSContext2D } from '@napi-rs/canvas';
import { addRoundedRectPath } from './rounded-rect.js';
import {
  STUDIO_BROWSER_WINDOW_RECT,
  STUDIO_WINDOW_BORDER,
  STUDIO_WINDOW_RADIUS,
  STUDIO_WINDOW_SHADOW,
} from './studio-layout.js';

export function drawStudioWindowShadow(context: SKRSContext2D): void {
  context.save();
  context.shadowColor = STUDIO_WINDOW_SHADOW.color;
  context.shadowBlur = STUDIO_WINDOW_SHADOW.blur;
  context.shadowOffsetX = STUDIO_WINDOW_SHADOW.offsetX;
  context.shadowOffsetY = STUDIO_WINDOW_SHADOW.offsetY;
  context.fillStyle = '#0F172A';
  addRoundedRectPath(context, STUDIO_BROWSER_WINDOW_RECT, STUDIO_WINDOW_RADIUS);
  context.fill();
  context.restore();
}

export function drawStudioWindowBorder(context: SKRSContext2D): void {
  context.save();
  context.lineWidth = STUDIO_WINDOW_BORDER.width;
  context.strokeStyle = STUDIO_WINDOW_BORDER.color;
  addRoundedRectPath(context, STUDIO_BROWSER_WINDOW_RECT, STUDIO_WINDOW_RADIUS);
  context.stroke();
  context.restore();
}
