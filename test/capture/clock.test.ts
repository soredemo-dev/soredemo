import { describe, expect, it } from 'vitest';
import {
  calibrationFromSample,
  driverMonotonicToBrowserEpochMs,
  selectLowestLatencyCalibration,
} from '../../src/capture/clock.js';

describe('capture clock calibration', () => {
  it('maps the browser epoch sample to the driver midpoint', () => {
    const calibration = calibrationFromSample({
      driverBeforeMs: 100,
      browserEpochMs: 1_750_000_000_105,
      driverAfterMs: 110,
    });

    expect(calibration).toEqual({
      browserEpochAtDriverZeroMs: 1_750_000_000_000,
      roundTripMs: 10,
      sampledAtDriverMs: 105,
    });
    expect(driverMonotonicToBrowserEpochMs(250, calibration)).toBe(1_750_000_000_250);
  });

  it('selects the lowest-round-trip startup sample', () => {
    const calibration = selectLowestLatencyCalibration([
      { driverBeforeMs: 10, browserEpochMs: 1_010, driverAfterMs: 30 },
      { driverBeforeMs: 40, browserEpochMs: 1_045, driverAfterMs: 50 },
      { driverBeforeMs: 60, browserEpochMs: 1_066, driverAfterMs: 72 },
    ]);

    expect(calibration.roundTripMs).toBe(10);
    expect(calibration.sampledAtDriverMs).toBe(45);
    expect(calibration.browserEpochAtDriverZeroMs).toBe(1_000);
  });

  it('rejects an empty sample set', () => {
    expect(() => selectLowestLatencyCalibration([])).toThrow(
      'Clock calibration requires at least one sample',
    );
  });
});
