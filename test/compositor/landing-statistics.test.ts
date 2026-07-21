import { describe, expect, it } from 'vitest';
import {
  type CursorLandingMeasurement,
  cursorLandingGatePasses,
  cursorLandingStatistics,
  measureCursorLanding,
} from '../../src/compositor/landing-statistics.js';
import type { ClickTimelineEvent } from '../../src/timeline/types.js';
import { frameRecord } from './helpers.js';

function click(id: string, testId = 'static-target'): ClickTimelineEvent {
  return {
    id,
    kind: 'click',
    startMs: 0,
    endMs: 20,
    target: { strategy: 'testId', value: { testId } },
    targetBboxAtPathStart: { x: 0, y: 0, width: 20, height: 20 },
    targetBboxAtCommit: { x: 0, y: 0, width: 20, height: 20 },
    clickPoint: { x: 10, y: 10 },
    cursorPath: [
      { x: 0, y: 0, timeMs: 0 },
      { x: 10, y: 10, timeMs: 10 },
    ],
    mouseDownMs: 12,
    mouseUpMs: 13,
  };
}

function measurement(
  id: string,
  errorXOutputPx: number,
  errorYOutputPx: number,
  targetTestId = 'static-target',
): CursorLandingMeasurement {
  return {
    clickId: id,
    targetTestId,
    mouseDownMs: 12,
    outputIndex: 0,
    outputTimestampMs: 0,
    selectedSourceIndex: 1,
    selectedSourceTimestampMs: 2,
    cursorCssX: 10,
    cursorCssY: 10,
    clickCssX: 10,
    clickCssY: 10,
    cursorScreenX: 12 + errorXOutputPx,
    cursorScreenY: 12 + errorYOutputPx,
    clickScreenX: 12,
    clickScreenY: 12,
    errorXOutputPx,
    errorYOutputPx,
    errorDistanceOutputPx: Math.hypot(errorXOutputPx, errorYOutputPx),
    cursorInterpolation: 'held',
    outputGridDeltaMs: -12,
    sourceToOutputDeltaMs: 2,
    sourceToMouseDownDeltaMs: -10,
  };
}

describe('cursor landing measurements', () => {
  it('preserves signed fractional axes and Euclidean distance', () => {
    const result = measureCursorLanding({
      click: click('click-001'),
      outputFrame: frameRecord(0),
      cursor: { visible: true, cssX: 10, cssY: 10, interpolation: 'held' },
      cursorScreen: { x: 12.25, y: 11.5 },
      clickScreen: { x: 12, y: 12 },
    });
    expect(result.errorXOutputPx).toBe(0.25);
    expect(result.errorYOutputPx).toBe(-0.5);
    expect(result.errorDistanceOutputPx).toBeCloseTo(Math.hypot(0.25, -0.5), 12);
    expect(result.cursorCssX).toBe(10);
    expect(result.clickCssX).toBe(10);
  });

  it('reports exact zero landing without independently changing the cursor point', () => {
    const result = measureCursorLanding({
      click: click('click-001'),
      outputFrame: frameRecord(0),
      cursor: { visible: true, cssX: 10, cssY: 10, interpolation: 'exact' },
      cursorScreen: { x: 12, y: 12 },
      clickScreen: { x: 12, y: 12 },
    });
    expect(result.errorDistanceOutputPx).toBe(0);
    expect(result.cursorInterpolation).toBe('exact');
  });

  it('includes every static and hover event in exact median and p95 statistics', () => {
    const measurements = Array.from({ length: 30 }, (_, index) =>
      measurement(
        `click-${String(index + 1).padStart(3, '0')}`,
        index === 29 ? 2 : index / 100,
        0,
        index % 2 === 0 ? 'static-target' : 'hover-target',
      ),
    );
    const statistics = cursorLandingStatistics(measurements);
    expect(statistics.clickCount).toBe(30);
    expect(statistics.distanceOutputPx.median).toBeCloseTo(0.145, 12);
    expect(statistics.distanceOutputPx.p95).toBeCloseTo(0.2755, 12);
    expect(statistics.distanceOutputPx.max).toBe(2);
    expect(statistics.worstClickId).toBe('click-030');
    expect(statistics.interpolationAtMouseDown.held).toBe(30);
    expect(measurements.filter((item) => item.targetTestId === 'static-target')).toHaveLength(15);
    expect(measurements.filter((item) => item.targetTestId === 'hover-target')).toHaveLength(15);
    expect(cursorLandingGatePasses(statistics)).toBe(true);
  });

  it('fails the fixed gate without excluding outliers', () => {
    const measurements = Array.from({ length: 30 }, (_, index) =>
      measurement(`click-${index}`, index < 27 ? 0 : 3, 0),
    );
    const statistics = cursorLandingStatistics(measurements);
    expect(statistics.failuresOverTwoPixels).toBe(3);
    expect(statistics.distanceOutputPx.p95).toBe(3);
    expect(cursorLandingGatePasses(statistics)).toBe(false);
  });
});
