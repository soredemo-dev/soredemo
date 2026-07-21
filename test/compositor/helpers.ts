import { createCanvas, type Image, loadImage } from '@napi-rs/canvas';
import type { ResampledFrameRecord } from '../../src/resample/types.js';

export function frameRecord(
  outputIndex: number,
  sourceIndex = outputIndex + 1,
): ResampledFrameRecord {
  const outputTimestampMs = (outputIndex * 1000) / 30;
  const sourceTimestampMs = outputTimestampMs + 2;
  return {
    outputIndex,
    outputTimestampMs,
    sourceIndex,
    sourceFile: `frames/${String(sourceIndex).padStart(6, '0')}.jpg`,
    sourceTimestampMs,
    signedSourceDeltaMs: 2,
    absoluteSourceDeltaMs: 2,
    relation: 'after',
  };
}

export async function solidImage(width: number, height: number, color: string): Promise<Image> {
  const canvas = createCanvas(width, height);
  const context = canvas.getContext('2d');
  context.fillStyle = color;
  context.fillRect(0, 0, width, height);
  return loadImage(canvas.toBuffer('image/png'));
}
