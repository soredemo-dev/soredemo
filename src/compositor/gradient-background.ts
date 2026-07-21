import type { SKRSContext2D } from '@napi-rs/canvas';
import { STUDIO_GRADIENT } from './studio-layout.js';
import { OUTPUT_HEIGHT, OUTPUT_WIDTH } from './types.js';

export function drawStudioGradient(context: SKRSContext2D): void {
  const gradient = context.createLinearGradient(
    STUDIO_GRADIENT.start.x,
    STUDIO_GRADIENT.start.y,
    STUDIO_GRADIENT.end.x,
    STUDIO_GRADIENT.end.y,
  );
  for (const stop of STUDIO_GRADIENT.stops) gradient.addColorStop(stop.offset, stop.color);
  context.globalCompositeOperation = 'copy';
  context.fillStyle = gradient;
  context.fillRect(0, 0, OUTPUT_WIDTH, OUTPUT_HEIGHT);
  context.globalCompositeOperation = 'source-over';
}
