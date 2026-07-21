import type { Rect } from './types.js';

function positiveFinite(value: number, name: string): void {
  if (!Number.isFinite(value) || value <= 0) throw new Error(`${name} must be positive and finite`);
}

export function containRect(
  sourceWidth: number,
  sourceHeight: number,
  outputWidth: number,
  outputHeight: number,
): Rect {
  positiveFinite(sourceWidth, 'sourceWidth');
  positiveFinite(sourceHeight, 'sourceHeight');
  positiveFinite(outputWidth, 'outputWidth');
  positiveFinite(outputHeight, 'outputHeight');

  const scale = Math.min(outputWidth / sourceWidth, outputHeight / sourceHeight);
  const width = Math.round(sourceWidth * scale);
  const height = Math.round(sourceHeight * scale);
  const x = Math.floor((outputWidth - width) / 2);
  const y = Math.floor((outputHeight - height) / 2);
  if (x < 0 || y < 0 || x + width > outputWidth || y + height > outputHeight) {
    throw new Error('Calculated contain rectangle escapes output bounds');
  }
  return { x, y, width, height };
}
