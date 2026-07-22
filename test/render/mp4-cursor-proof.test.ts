import { describe, expect, it } from 'vitest';
import { compareRgba } from '../../src/render/mp4-cursor-proof.js';

describe('MP4 cursor proof comparison', () => {
  it('reports exact and lossy channel differences', () => {
    expect(compareRgba(new Uint8Array([1, 2, 3, 255]), new Uint8Array([1, 2, 3, 255]))).toEqual({
      meanAbsoluteError: 0,
      rgbMeanAbsoluteError: 0,
      rgbPsnr: Number.POSITIVE_INFINITY,
      alphaMeanAbsoluteError: 0,
      maximumChannelError: 0,
    });
    const lossy = compareRgba(new Uint8Array([0, 10, 20, 255]), new Uint8Array([2, 8, 26, 255]));
    expect(lossy).toMatchObject({
      meanAbsoluteError: 2.5,
      rgbMeanAbsoluteError: 10 / 3,
      alphaMeanAbsoluteError: 0,
      maximumChannelError: 6,
    });
    expect(lossy.rgbPsnr).toBeCloseTo(36.4675, 3);
  });

  it('rejects incompatible buffers', () => {
    expect(() => compareRgba(new Uint8Array(), new Uint8Array())).toThrow('nonzero');
    expect(() => compareRgba(new Uint8Array([1]), new Uint8Array([1, 2]))).toThrow('equal');
  });
});
