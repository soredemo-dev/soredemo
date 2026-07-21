import { describe, expect, it } from 'vitest';
import {
  clampCameraState,
  pointInsideRect,
  projectCssPoint,
  projectCssRect,
  sourceCropForCamera,
  visibleCssRect,
  visibleFraction,
} from '../../src/compositor/camera-projection.js';

const viewport = { width: 1440, height: 900 };
const content = { x: 96, y: 0, width: 1728, height: 1080 };

describe('camera geometry and projection', () => {
  it('uses the complete viewport at zoom one', () => {
    expect(visibleCssRect({ zoom: 1, centerCssX: 720, centerCssY: 450 }, viewport)).toEqual({
      x: 0,
      y: 0,
      width: 1440,
      height: 900,
    });
  });

  it.each([
    [0, 0, 533.3333333333334, 333.33333333333337],
    [1440, 0, 906.6666666666666, 333.33333333333337],
    [0, 900, 533.3333333333334, 566.6666666666666],
    [1440, 900, 906.6666666666666, 566.6666666666666],
  ])('clamps a 1.35 camera at edge %s,%s', (x, y, centerCssX, centerCssY) => {
    const state = clampCameraState({ zoom: 1.35, centerCssX: x, centerCssY: y }, viewport);
    expect(state.zoom).toBe(1.35);
    expect(state.centerCssX).toBeCloseTo(centerCssX, 12);
    expect(state.centerCssY).toBeCloseTo(centerCssY, 12);
  });

  it('converts CSS crop to the two-times source scale', () => {
    expect(
      sourceCropForCamera({ zoom: 1.25, centerCssX: 720, centerCssY: 450 }, viewport, {
        width: 2880,
        height: 1800,
      }),
    ).toEqual({ x: 288, y: 180, width: 2304, height: 1440 });
  });

  it('matches the Day-6 projection at zoom one', () => {
    const camera = { zoom: 1, centerCssX: 720, centerCssY: 450 };
    expect(projectCssPoint({ x: 0, y: 0 }, camera, viewport, content)).toEqual({ x: 96, y: 0 });
    expect(projectCssPoint({ x: 1440, y: 900 }, camera, viewport, content)).toEqual({
      x: 1824,
      y: 1080,
    });
    expect(projectCssPoint({ x: 100.25, y: 200.5 }, camera, viewport, content)).toEqual({
      x: 216.3,
      y: 240.6,
    });
  });

  it('projects points and bbox corners through one camera path', () => {
    const camera = { zoom: 1.35, centerCssX: 720, centerCssY: 450 };
    const rect = projectCssRect(
      { x: 700, y: 430, width: 40, height: 40 },
      camera,
      viewport,
      content,
    );
    expect(rect.width).toBeCloseTo(64.8);
    expect(rect.height).toBeCloseTo(64.8);
    expect(
      pointInsideRect(projectCssPoint({ x: 720, y: 450 }, camera, viewport, content), rect),
    ).toBe(true);
    expect(visibleFraction(rect, content)).toBe(1);
  });

  it('rejects invalid camera and mismatched source geometry', () => {
    expect(() => visibleCssRect({ zoom: 0.9, centerCssX: 0, centerCssY: 0 }, viewport)).toThrow(
      /zoom/,
    );
    expect(() =>
      sourceCropForCamera({ zoom: 1, centerCssX: 720, centerCssY: 450 }, viewport, {
        width: 2880,
        height: 1700,
      }),
    ).toThrow(/scales/);
    expect(() =>
      projectCssPoint(
        { x: Number.NaN, y: 0 },
        { zoom: 1, centerCssX: 720, centerCssY: 450 },
        viewport,
        content,
      ),
    ).toThrow(/finite/);
  });
});
