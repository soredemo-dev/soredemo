import { describe, expect, it } from 'vitest';
import { cssPointToScreen } from '../../src/compositor/cursor-coordinate-transform.js';

const viewport = { width: 1440, height: 900 };
const contentRect = { x: 96, y: 0, width: 1728, height: 1080 };

describe('cursor coordinate transform', () => {
  it('maps viewport corners to content corners', () => {
    expect(cssPointToScreen({ x: 0, y: 0 }, viewport, contentRect)).toEqual({ x: 96, y: 0 });
    expect(cssPointToScreen({ x: 1440, y: 900 }, viewport, contentRect)).toEqual({
      x: 1824,
      y: 1080,
    });
  });

  it('uses the 1.2 CSS-to-screen scale and preserves fractions', () => {
    expect(cssPointToScreen({ x: 100, y: 50 }, viewport, contentRect)).toEqual({
      x: 216,
      y: 60,
    });
    expect(cssPointToScreen({ x: 0.25, y: 0.125 }, viewport, contentRect)).toEqual({
      x: 96.3,
      y: 0.15,
    });
  });

  it('does not use source JPEG dimensions and rejects invalid points', () => {
    expect(cssPointToScreen({ x: 720, y: 450 }, viewport, contentRect)).toEqual({
      x: 960,
      y: 540,
    });
    for (const point of [
      { x: -1, y: 0 },
      { x: 0, y: 901 },
      { x: Number.NaN, y: 0 },
    ]) {
      expect(() => cssPointToScreen(point, viewport, contentRect)).toThrow('inside the viewport');
    }
  });
});
