import { createRequire } from 'node:module';
import type { Point } from '../timeline/types.js';

const require = createRequire(import.meta.url);

interface GhostTimedPoint extends Point {
  timestamp: number;
}

const ghostPath = (
  require('ghost-cursor') as {
    path(
      start: Point,
      end: Point,
      options: { useTimestamps: true; moveSpeed: number },
    ): GhostTimedPoint[];
  }
).path;

export interface PlannedCursorPoint extends Point {
  plannedOffsetMs: number;
}

export interface ViewportBounds {
  width: number;
  height: number;
}

export function validatePathGeometry(points: Point[], viewport: ViewportBounds): void {
  if (points.length < 2) throw new Error('Cursor path must contain at least two points');
  for (const point of points) {
    if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) {
      throw new Error('Cursor path contains a non-finite coordinate');
    }
    if (point.x < 0 || point.x > viewport.width || point.y < 0 || point.y > viewport.height) {
      throw new Error('Cursor path leaves the CSS viewport');
    }
  }
}

export function normalizeProposedPathTiming(
  points: GhostTimedPoint[],
  durationMs: number,
): PlannedCursorPoint[] {
  if (!Number.isFinite(durationMs) || durationMs <= 0) {
    throw new Error('Cursor movement duration must be positive');
  }
  const coalesced: GhostTimedPoint[] = [];
  for (const point of points) {
    const previous = coalesced.at(-1);
    if (previous?.timestamp === point.timestamp) {
      if (coalesced.length > 1) coalesced[coalesced.length - 1] = point;
    } else coalesced.push(point);
  }
  const firstTimestamp = coalesced[0]?.timestamp;
  const lastTimestamp = coalesced.at(-1)?.timestamp;
  if (
    firstTimestamp === undefined ||
    lastTimestamp === undefined ||
    !Number.isFinite(firstTimestamp) ||
    !Number.isFinite(lastTimestamp) ||
    lastTimestamp <= firstTimestamp
  ) {
    throw new Error('Ghost cursor path has no usable relative timing span');
  }
  const scale = durationMs / (lastTimestamp - firstTimestamp);
  const normalized = coalesced.map((point) => ({
    x: point.x,
    y: point.y,
    plannedOffsetMs: (point.timestamp - firstTimestamp) * scale,
  }));
  for (let index = 1; index < normalized.length; index += 1) {
    if (
      (normalized[index]?.plannedOffsetMs ?? 0) <= (normalized[index - 1]?.plannedOffsetMs ?? 0)
    ) {
      throw new Error('Ghost cursor relative timestamps are not strictly increasing');
    }
  }
  return normalized;
}

export function movementDurationMs(start: Point, end: Point): number {
  const distance = Math.hypot(end.x - start.x, end.y - start.y);
  return Math.min(900, Math.max(450, 450 + distance * 0.45));
}

export function generateCursorPath(options: {
  start: Point;
  end: Point;
  viewport: ViewportBounds;
  maxAttempts?: number;
}): PlannedCursorPoint[] {
  const attempts = options.maxAttempts ?? 12;
  const durationMs = movementDurationMs(options.start, options.end);
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const proposed = ghostPath(options.start, options.end, {
      useTimestamps: true,
      moveSpeed: 10,
    });
    try {
      validatePathGeometry(proposed, options.viewport);
      const finalPoint = proposed.at(-1);
      if (!finalPoint || finalPoint.x !== options.end.x || finalPoint.y !== options.end.y) {
        throw new Error('Ghost cursor path does not end at the click point');
      }
      return normalizeProposedPathTiming(proposed, durationMs);
    } catch (error) {
      if (attempt === attempts) {
        const message = error instanceof Error ? error.message : String(error);
        throw new Error(
          `Unable to generate a valid cursor path after ${attempts} attempts: ${message}`,
        );
      }
    }
  }
  throw new Error('Cursor path generation exhausted unexpectedly');
}
