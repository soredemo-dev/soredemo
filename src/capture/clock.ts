import { performance } from 'node:perf_hooks';
import type { ClockCalibration } from './types.js';

export interface ClockSample {
  driverBeforeMs: number;
  browserEpochMs: number;
  driverAfterMs: number;
}

export function calibrationFromSample(sample: ClockSample): ClockCalibration {
  const sampledAtDriverMs = (sample.driverBeforeMs + sample.driverAfterMs) / 2;
  return {
    browserEpochAtDriverZeroMs: sample.browserEpochMs - sampledAtDriverMs,
    roundTripMs: sample.driverAfterMs - sample.driverBeforeMs,
    sampledAtDriverMs,
  };
}

export function selectLowestLatencyCalibration(samples: ClockSample[]): ClockCalibration {
  if (samples.length === 0) throw new Error('Clock calibration requires at least one sample');
  const calibrations = samples.map(calibrationFromSample);
  const selected = calibrations.reduce((lowest, candidate) =>
    candidate.roundTripMs < lowest.roundTripMs ? candidate : lowest,
  );
  if (!Number.isFinite(selected.browserEpochAtDriverZeroMs) || selected.roundTripMs < 0) {
    throw new Error('Clock calibration produced invalid values');
  }
  return selected;
}

export async function calibrateBrowserEpoch(
  sampleBrowserEpochMs: () => Promise<number>,
  sampleCount = 9,
  driverNow: () => number = () => performance.now(),
): Promise<ClockCalibration> {
  if (!Number.isInteger(sampleCount) || sampleCount < 1) {
    throw new Error('Clock calibration sample count must be a positive integer');
  }

  const samples: ClockSample[] = [];
  for (let index = 0; index < sampleCount; index += 1) {
    const driverBeforeMs = driverNow();
    const browserEpochMs = await sampleBrowserEpochMs();
    const driverAfterMs = driverNow();
    samples.push({ driverBeforeMs, browserEpochMs, driverAfterMs });
  }
  return selectLowestLatencyCalibration(samples);
}

export function driverMonotonicToBrowserEpochMs(
  driverMonotonicMs: number,
  calibration: ClockCalibration,
): number {
  return driverMonotonicMs + calibration.browserEpochAtDriverZeroMs;
}
