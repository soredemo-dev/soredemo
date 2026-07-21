import { describe, expect, it } from 'vitest';
import { compareRgba } from '../../src/render/mp4-cursor-proof.js';

describe('MP4 cursor proof comparison', () => {
  it('reports exact and lossy channel differences', () => {
    expect(compareRgba(new Uint8Array([1, 2, 3, 255]), new Uint8Array([1, 2, 3, 255]))).toEqual({
      meanAbsoluteError: 0,
      maximumChannelError: 0,
    });
    expect(compareRgba(new Uint8Array([0, 10, 20, 255]), new Uint8Array([2, 8, 26, 255]))).toEqual({
      meanAbsoluteError: 2.5,
      maximumChannelError: 6,
    });
  });

  it('rejects incompatible buffers', () => {
    expect(() => compareRgba(new Uint8Array(), new Uint8Array())).toThrow('nonzero');
    expect(() => compareRgba(new Uint8Array([1]), new Uint8Array([1, 2]))).toThrow('equal');
  });
});
