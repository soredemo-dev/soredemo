import { performance } from 'node:perf_hooks';
import { setTimeout } from 'node:timers/promises';
import type { TimedPoint } from '../timeline/types.js';
import { driverMonotonicToBrowserEpochMs } from './clock.js';
import type { PlannedCursorPoint } from './cursor-path.js';
import type { ClockCalibration } from './types.js';

export interface MouseMover {
  move(x: number, y: number): Promise<void>;
}

export interface DispatchedMousePath {
  cursorPath: TimedPoint[];
  roundTripMs: number[];
}

export function driverMidpointToCaptureTimeMs(
  beforeMs: number,
  afterMs: number,
  calibration: ClockCalibration,
  captureOriginEpochMs: number,
): number {
  return (
    driverMonotonicToBrowserEpochMs((beforeMs + afterMs) / 2, calibration) - captureOriginEpochMs
  );
}

export async function dispatchMousePath(options: {
  mouse: MouseMover;
  points: PlannedCursorPoint[];
  calibration: ClockCalibration;
  captureOriginEpochMs: number;
  driverNow?: () => number;
  wait?: (durationMs: number) => Promise<void>;
}): Promise<DispatchedMousePath> {
  const driverNow = options.driverNow ?? (() => performance.now());
  const wait = options.wait ?? ((durationMs: number) => setTimeout(durationMs));
  const scheduleOriginMs = driverNow();
  const cursorPath: TimedPoint[] = [];
  const roundTripMs: number[] = [];

  for (const point of options.points) {
    const remainingMs = scheduleOriginMs + point.plannedOffsetMs - driverNow();
    if (remainingMs > 0) await wait(remainingMs);
    const beforeMs = driverNow();
    await options.mouse.move(point.x, point.y);
    const afterMs = driverNow();
    const timeMs = driverMidpointToCaptureTimeMs(
      beforeMs,
      afterMs,
      options.calibration,
      options.captureOriginEpochMs,
    );
    const previous = cursorPath.at(-1);
    if (previous && timeMs <= previous.timeMs) {
      throw new Error('Measured cursor path timestamps are not strictly increasing');
    }
    cursorPath.push({ x: point.x, y: point.y, timeMs });
    roundTripMs.push(afterMs - beforeMs);
  }

  return { cursorPath, roundTripMs };
}
