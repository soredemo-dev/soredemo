import { describe, expect, it } from 'vitest';
import { analyzeMouseDownFrameWindow } from '../../src/capture/frame-cadence.js';
import type { CapturedFrameRecord } from '../../src/capture/types.js';

function record(index: number, timestampMs: number): CapturedFrameRecord {
  return {
    index,
    file: `frames/${String(index).padStart(6, '0')}.jpg`,
    timestampMs,
    pixelWidth: 2880,
    pixelHeight: 1800,
    pageScaleFactor: 1,
    scrollOffsetX: 0,
    scrollOffsetY: 0,
    offsetTop: 0,
    receivedAtMs: timestampMs + 2,
  };
}

describe('mouse-down frame cadence', () => {
  it('uses CDP timestamps around the mouse-down window', () => {
    const records = [0, 90, 180, 270, 360, 450, 540].map((time, index) => record(index + 1, time));
    expect(analyzeMouseDownFrameWindow(records, 300, 150)).toEqual({
      maxGapMs: 90,
      nearestBeforeMs: 270,
      nearestAfterMs: 360,
      nearestDistanceMs: 30,
      frameCount: 4,
    });
  });
});
