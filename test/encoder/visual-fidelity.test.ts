import { describe, expect, it } from 'vitest';
import { measureRgbaFidelity } from '../../src/encoder/visual-fidelity.js';

describe('RGBA visual fidelity', () => {
  it('reports exact identity', () => {
    const result = measureRgbaFidelity(
      Uint8Array.from([10, 20, 30, 255]),
      Uint8Array.from([10, 20, 30, 255]),
    );
    expect(result.meanAbsoluteError).toEqual({ red: 0, green: 0, blue: 0, alpha: 0 });
    expect(result.rgbPsnrDb).toBe(Number.POSITIVE_INFINITY);
    expect(result.maximumChannelError).toBe(0);
  });

  it('measures per-channel error and RGB PSNR', () => {
    const result = measureRgbaFidelity(
      Uint8Array.from([10, 20, 30, 255, 0, 0, 0, 255]),
      Uint8Array.from([12, 16, 36, 250, 0, 0, 0, 255]),
    );
    expect(result.meanAbsoluteError).toEqual({ red: 1, green: 2, blue: 3, alpha: 2.5 });
    expect(result.rgbPsnrDb).toBeGreaterThan(35);
    expect(result.maximumChannelError).toBe(6);
  });

  it('rejects empty and mismatched buffers', () => {
    expect(() => measureRgbaFidelity(new Uint8Array(), new Uint8Array())).toThrow('not be empty');
    expect(() => measureRgbaFidelity(new Uint8Array(4), new Uint8Array(8))).toThrow('equal');
  });
});
