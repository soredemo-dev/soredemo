import { type Canvas, createCanvas, type SKRSContext2D } from '@napi-rs/canvas';
import { addRoundedRectPath } from './rounded-rect.js';
import {
  STUDIO_BROWSER_WINDOW_RECT,
  STUDIO_WINDOW_BORDER,
  STUDIO_WINDOW_RADIUS,
  STUDIO_WINDOW_SHADOW,
} from './studio-layout.js';
import type { Rect } from './types.js';

export const STUDIO_SHADOW_LAYER_RECT: Readonly<Rect> = {
  x: 200,
  y: 24,
  width: 1520,
  height: 1056,
};

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

export function createStudioWindowShadowLayer(): Canvas {
  const canvas = createCanvas(STUDIO_SHADOW_LAYER_RECT.width, STUDIO_SHADOW_LAYER_RECT.height);
  const context = canvas.getContext('2d');
  context.translate(-STUDIO_SHADOW_LAYER_RECT.x, -STUDIO_SHADOW_LAYER_RECT.y);
  drawStudioWindowShadow(context);
  return canvas;
}
