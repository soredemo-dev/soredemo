import type { CapturedFrameRecord } from './types.js';

export interface MouseDownFrameWindow {
  maxGapMs: number;
  nearestBeforeMs: number;
  nearestAfterMs: number;
  nearestDistanceMs: number;
  frameCount: number;
}

export function analyzeMouseDownFrameWindow(
  records: CapturedFrameRecord[],
  mouseDownMs: number,
  radiusMs = 250,
): MouseDownFrameWindow {
  if (records.length < 2) throw new Error('Frame cadence analysis requires at least two frames');
  const before = records.filter((record) => record.timestampMs <= mouseDownMs).at(-1);
  const after = records.find((record) => record.timestampMs >= mouseDownMs);
  if (!before || !after) throw new Error('Mouse down falls outside the captured frame range');

  const windowStart = mouseDownMs - radiusMs;
  const windowEnd = mouseDownMs + radiusMs;
  let maxGapMs = 0;
  for (let index = 1; index < records.length; index += 1) {
    const previous = records[index - 1];
    const current = records[index];
    if (!previous || !current) continue;
    if (previous.timestampMs <= windowEnd && current.timestampMs >= windowStart) {
      maxGapMs = Math.max(maxGapMs, current.timestampMs - previous.timestampMs);
    }
  }
  const framesInWindow = records.filter(
    (record) => record.timestampMs >= windowStart && record.timestampMs <= windowEnd,
  );
  return {
    maxGapMs,
    nearestBeforeMs: before.timestampMs,
    nearestAfterMs: after.timestampMs,
    nearestDistanceMs: Math.min(mouseDownMs - before.timestampMs, after.timestampMs - mouseDownMs),
    frameCount: framesInWindow.length,
  };
}
