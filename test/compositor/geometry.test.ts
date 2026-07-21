import { describe, expect, it } from 'vitest';
import { containRect } from '../../src/compositor/geometry.js';

describe('contain geometry', () => {
  it('fits the Day-5 source into the fixed output contract', () => {
    expect(containRect(2880, 1800, 1920, 1080)).toEqual({
      x: 96,
      y: 0,
      width: 1728,
      height: 1080,
    });
  });

  it('fills equal-aspect output and centers portrait content', () => {
    expect(containRect(1600, 900, 1920, 1080)).toEqual({
      x: 0,
      y: 0,
      width: 1920,
      height: 1080,
    });
    expect(containRect(900, 1600, 1920, 1080)).toEqual({
      x: 656,
      y: 0,
      width: 608,
      height: 1080,
    });
  });

  it('uses rounded size and floor-centered odd leftover pixels', () => {
    expect(containRect(2, 3, 10, 10)).toEqual({ x: 1, y: 0, width: 7, height: 10 });
  });

  it('rejects invalid dimensions and never escapes output bounds', () => {
    const invalidDimensions: Array<[number, number, number, number]> = [
      [0, 10, 10, 10],
      [-1, 10, 10, 10],
      [10, Number.NaN, 10, 10],
      [10, 10, Number.POSITIVE_INFINITY, 10],
    ];
    for (const dimensions of invalidDimensions) {
      const [sourceWidth, sourceHeight, outputWidth, outputHeight] = dimensions;
      expect(() => containRect(sourceWidth, sourceHeight, outputWidth, outputHeight)).toThrow(
        'positive and finite',
      );
    }
    const rect = containRect(101, 57, 1919, 1079);
    expect(rect.x).toBeGreaterThanOrEqual(0);
    expect(rect.y).toBeGreaterThanOrEqual(0);
    expect(rect.x + rect.width).toBeLessThanOrEqual(1919);
    expect(rect.y + rect.height).toBeLessThanOrEqual(1079);
  });
});
