import { describe, expect, it } from 'vitest';
import { dispatchMousePath } from '../../src/capture/mouse-dispatch.js';

describe('dispatchMousePath', () => {
  it('uses measured command midpoints on the capture-relative clock', async () => {
    const times = [100, 100, 101, 103, 104, 111, 113];
    const moved: Array<{ x: number; y: number }> = [];
    const result = await dispatchMousePath({
      mouse: {
        move: async (x, y) => {
          moved.push({ x, y });
        },
      },
      points: [
        { x: 10, y: 20, plannedOffsetMs: 0 },
        { x: 30, y: 40, plannedOffsetMs: 10 },
      ],
      calibration: {
        browserEpochAtDriverZeroMs: 1_000,
        roundTripMs: 1,
        sampledAtDriverMs: 50,
      },
      captureOriginEpochMs: 1_000,
      driverNow: () => times.shift() ?? 113,
      wait: async () => {},
    });
    expect(moved).toEqual([
      { x: 10, y: 20 },
      { x: 30, y: 40 },
    ]);
    expect(result.cursorPath.map((point) => point.timeMs)).toEqual([102, 112]);
    expect(result.roundTripMs).toEqual([2, 2]);
  });
});
