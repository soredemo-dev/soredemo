import { describe, expect, it } from 'vitest';
import {
  mapEventToOutputFrame,
  nearestOutputIndex,
} from '../../src/resample/event-frame-mapping.js';
import type { ResampledFrameRecord } from '../../src/resample/types.js';

function selected(outputIndex: number, sourceTimestampMs: number): ResampledFrameRecord {
  const outputTimestampMs = (outputIndex * 1000) / 30;
  const signedSourceDeltaMs = sourceTimestampMs - outputTimestampMs;
  return {
    outputIndex,
    outputTimestampMs,
    sourceIndex: 10,
    sourceFile: 'frames/000010.jpg',
    sourceTimestampMs,
    signedSourceDeltaMs,
    absoluteSourceDeltaMs: Math.abs(signedSourceDeltaMs),
    relation: signedSourceDeltaMs < 0 ? 'before' : signedSourceDeltaMs > 0 ? 'after' : 'exact',
  };
}

describe('event to output-frame mapping', () => {
  it('maps exact and between-frame events', () => {
    expect(nearestOutputIndex(100, 100)).toBe(3);
    expect(nearestOutputIndex(120, 100)).toBe(4);
  });

  it('chooses the earlier frame at an exact half-frame tie', () => {
    expect(nearestOutputIndex(1000 / 60, 100)).toBe(0);
  });

  it('clamps only at capture boundaries', () => {
    expect(nearestOutputIndex(-4, 10)).toBe(0);
    expect(nearestOutputIndex(10_000, 10)).toBe(9);
  });

  it('keeps output, source, and event timestamps separate with signed deltas', () => {
    const mapping = mapEventToOutputFrame({
      eventTimestampMs: 101,
      outputFrameCount: 100,
      selectedFrame: selected(3, 96),
    });
    expect(mapping).toMatchObject({
      outputIndex: 3,
      outputTimestampMs: 100,
      signedOutputDeltaMs: -1,
      selectedSourceTimestampMs: 96,
      signedSourceToEventDeltaMs: -5,
      absoluteSourceToEventDeltaMs: 5,
    });
  });
});
