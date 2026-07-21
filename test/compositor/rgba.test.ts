import { createCanvas } from '@napi-rs/canvas';
import { describe, expect, it } from 'vitest';
import { isOpaqueRgba, rgbaBytes } from '../../src/compositor/rgba.js';

describe('RGBA extraction', () => {
  it('preserves RGBA channel order and left-to-right, top-to-bottom rows', () => {
    const canvas = createCanvas(2, 2);
    const context = canvas.getContext('2d');
    const colors = ['#ff0000', '#00ff00', '#0000ff', '#ffffff'];
    for (const [index, color] of colors.entries()) {
      context.fillStyle = color;
      context.fillRect(index % 2, Math.floor(index / 2), 1, 1);
    }
    const bytes = rgbaBytes(context.getImageData(0, 0, 2, 2).data);
    expect([...bytes]).toEqual([
      255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255,
    ]);
    expect(isOpaqueRgba(bytes)).toBe(true);
  });

  it('detects transparency and rejects malformed byte lengths', () => {
    expect(isOpaqueRgba(new Uint8Array([0, 0, 0, 254]))).toBe(false);
    expect(() => isOpaqueRgba(new Uint8Array(3))).toThrow('divisible by four');
  });
});
