import { createCanvas, loadImage } from '@napi-rs/canvas';
import type { Rect } from '../../src/compositor/types.js';
import type { PixelDifferenceStatistics } from './types.js';

export function compareRgba(
  expected: Uint8Array,
  actual: Uint8Array,
  width: number,
  height: number,
): { statistics: PixelDifferenceStatistics; difference: Uint8Array; heatmap: Uint8Array } {
  if (expected.byteLength !== actual.byteLength || expected.byteLength !== width * height * 4) {
    throw new Error('RGBA comparison dimensions do not match');
  }
  const difference = new Uint8Array(expected.byteLength);
  const heatmap = new Uint8Array(expected.byteLength);
  const sums = [0, 0, 0, 0];
  let maximumChannelError = 0;
  let differingPixels = 0;
  let left = width;
  let top = height;
  let right = -1;
  let bottom = -1;
  for (let pixel = 0; pixel < width * height; pixel += 1) {
    const offset = pixel * 4;
    let pixelMaximum = 0;
    for (let channel = 0; channel < 4; channel += 1) {
      const delta = Math.abs((actual[offset + channel] ?? 0) - (expected[offset + channel] ?? 0));
      sums[channel] = (sums[channel] ?? 0) + delta;
      difference[offset + channel] = channel === 3 ? 255 : delta;
      maximumChannelError = Math.max(maximumChannelError, delta);
      pixelMaximum = Math.max(pixelMaximum, delta);
    }
    heatmap[offset] = Math.min(255, pixelMaximum * 8);
    heatmap[offset + 1] = pixelMaximum === 0 ? 0 : Math.min(255, pixelMaximum * 2);
    heatmap[offset + 2] = 0;
    heatmap[offset + 3] = 255;
    if (pixelMaximum > 0) {
      differingPixels += 1;
      const x = pixel % width;
      const y = Math.floor(pixel / width);
      left = Math.min(left, x);
      top = Math.min(top, y);
      right = Math.max(right, x);
      bottom = Math.max(bottom, y);
    }
  }
  const totalPixels = width * height;
  const boundingBox: Rect | undefined =
    differingPixels === 0
      ? undefined
      : { x: left, y: top, width: right - left + 1, height: bottom - top + 1 };
  return {
    statistics: {
      differingPixels,
      totalPixels,
      differingFraction: differingPixels / totalPixels,
      absoluteError: {
        redMean: (sums[0] ?? 0) / totalPixels,
        greenMean: (sums[1] ?? 0) / totalPixels,
        blueMean: (sums[2] ?? 0) / totalPixels,
        alphaMean: (sums[3] ?? 0) / totalPixels,
        maximumChannelError,
      },
      ...(boundingBox ? { boundingBox } : {}),
    },
    difference,
    heatmap,
  };
}

export function rgbaToPng(data: Uint8Array, width: number, height: number): Buffer {
  if (data.byteLength !== width * height * 4) throw new Error('RGBA PNG dimensions do not match');
  const canvas = createCanvas(width, height);
  canvas.data().set(data);
  return canvas.toBuffer('image/png');
}

export async function pngToRgba(
  source: Buffer | Uint8Array,
): Promise<{ data: Uint8Array; width: number; height: number }> {
  const image = await loadImage(source);
  const canvas = createCanvas(image.width, image.height);
  canvas.getContext('2d').drawImage(image, 0, 0);
  return { data: new Uint8Array(canvas.data()), width: image.width, height: image.height };
}
