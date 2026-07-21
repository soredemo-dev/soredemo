import { describe, expect, it } from 'vitest';
import {
  outputClock,
  outputFrameCount,
  outputTimestampForIndex,
} from '../../src/resample/output-clock.js';

describe('fixed output clock', () => {
  it('rejects invalid durations', () => {
    expect(() => outputFrameCount(-1)).toThrow('non-negative');
    expect(() => outputFrameCount(Number.NaN)).toThrow('finite');
  });

  it('emits one frame for a zero-duration capture', () => {
    expect([...outputClock(0)]).toEqual([{ outputIndex: 0, outputTimestampMs: 0 }]);
  });

  it('handles exact and non-boundary source durations without an extra frame', () => {
    const exact = [...outputClock(1000)];
    expect(exact).toHaveLength(31);
    expect(exact.at(-1)?.outputTimestampMs).toBe(1000);
    const nonBoundary = [...outputClock(1010)];
    expect(nonBoundary).toHaveLength(31);
    expect(nonBoundary.at(-1)?.outputTimestampMs).toBe(1000);
  });

  it('derives every timestamp directly from its integer index without cumulative drift', () => {
    const multiHourIndex = 1_000_000;
    expect(outputTimestampForIndex(multiHourIndex)).toBe((multiHourIndex * 1000) / 30);
    const durationMs = 4 * 60 * 60 * 1000 + 17;
    const final = [...outputClock(durationMs)].at(-1);
    expect(final?.outputTimestampMs).toBe(
      outputTimestampForIndex(outputFrameCount(durationMs) - 1),
    );
    expect(final?.outputTimestampMs).toBeLessThanOrEqual(durationMs);
  });
});
