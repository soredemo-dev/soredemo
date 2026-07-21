import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { BaseFrameCompositor } from '../../src/compositor/base-frame-compositor.js';
import { isOpaqueRgba } from '../../src/compositor/rgba.js';
import type { CompositionFrameContext } from '../../src/compositor/types.js';
import { solidImage } from './helpers.js';

const frameContext: CompositionFrameContext = {
  outputIndex: 0,
  outputTimestampMs: 0,
  sourceIndex: 1,
  sourceFile: 'frames/000001.jpg',
  sourceTimestampMs: 2,
  signedSourceDeltaMs: 2,
};

function pixel(data: Uint8Array, x: number, y: number): number[] {
  const offset = (y * 1920 + x) * 4;
  return [...data.subarray(offset, offset + 4)];
}

describe('base frame compositor', () => {
  it('fills matte outside the contained source and keeps every pixel opaque', async () => {
    const compositor = new BaseFrameCompositor(2, 1);
    const frame = compositor.compose(frameContext, await solidImage(2, 1, 'rgba(255, 0, 0, 0.5)'));
    expect(compositor.contentRect).toEqual({ x: 0, y: 60, width: 1920, height: 960 });
    expect(pixel(frame.data, 0, 0)).toEqual([0, 0, 0, 255]);
    expect(pixel(frame.data, 960, 540)).toEqual([127, 0, 0, 255]);
    expect(isOpaqueRgba(frame.data)).toBe(true);
  });

  it('fully overwrites prior frame pixels and is deterministic', async () => {
    const compositor = new BaseFrameCompositor(2, 1);
    const red = await solidImage(2, 1, '#ff0000');
    const blue = await solidImage(2, 1, '#0000ff');
    compositor.compose(frameContext, red);
    const firstBlue = compositor.compose(frameContext, blue);
    const firstHash = createHash('sha256').update(firstBlue.data).digest('hex');
    const secondBlue = compositor.compose(frameContext, blue);
    expect(createHash('sha256').update(secondBlue.data).digest('hex')).toBe(firstHash);
    expect(pixel(secondBlue.data, 960, 540)).toEqual([0, 0, 255, 255]);
  });

  it('rejects a decoded image with changed dimensions', async () => {
    const compositor = new BaseFrameCompositor(2, 1);
    const image = await solidImage(1, 1, '#fff');
    expect(() => compositor.compose(frameContext, image)).toThrow('dimensions changed');
  });
});
