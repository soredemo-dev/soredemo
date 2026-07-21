import { describe, expect, it } from 'vitest';
import {
  generateCursorPath,
  normalizeProposedPathTiming,
  validatePathGeometry,
} from '../../src/capture/cursor-path.js';

describe('cursor paths', () => {
  it('rejects paths that leave the CSS viewport', () => {
    expect(() =>
      validatePathGeometry(
        [
          { x: 20, y: 20 },
          { x: 1441, y: 30 },
        ],
        { width: 1440, height: 900 },
      ),
    ).toThrow('leaves the CSS viewport');
  });

  it('normalizes package timestamps into a requested relative duration', () => {
    expect(
      normalizeProposedPathTiming(
        [
          { x: 0, y: 0, timestamp: 10_000 },
          { x: 5, y: 5, timestamp: 10_025 },
          { x: 10, y: 10, timestamp: 10_100 },
        ],
        800,
      ).map((point) => point.plannedOffsetMs),
    ).toEqual([0, 200, 800]);
  });

  it('uses the generated path endpoint as the exact click point', () => {
    const end = { x: 720, y: 250 };
    const points = generateCursorPath({
      start: { x: 80, y: 760 },
      end,
      viewport: { width: 1440, height: 900 },
    });
    expect(points.at(-1)).toMatchObject(end);
    expect(points.every((point) => Number.isFinite(point.x) && Number.isFinite(point.y))).toBe(
      true,
    );
  });
});
