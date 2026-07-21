import { describe, expect, it } from 'vitest';
import {
  cameraMotionStatistics,
  measureTargetFraming,
} from '../../src/compositor/camera-statistics.js';
import type { CameraFrameState, CameraTrack } from '../../src/compositor/camera-types.js';
import type { ClickTimelineEvent } from '../../src/timeline/types.js';

const viewport = { width: 1440, height: 900 };
const contentRect = { x: 96, y: 0, width: 1728, height: 1080 };
const camera: CameraFrameState = {
  zoom: 1.35,
  centerCssX: 720,
  centerCssY: 450,
  outputTimestampMs: 1000,
  segmentId: 'hold',
  phase: 'hold',
  visibleCssRect: {
    x: 186.66666666666663,
    y: 116.66666666666663,
    width: 1066.6666666666667,
    height: 666.6666666666666,
  },
};
const click: ClickTimelineEvent = {
  id: 'click-001',
  kind: 'click',
  startMs: 500,
  endMs: 1010,
  target: { strategy: 'testId', value: { testId: 'static-target' } },
  targetBboxAtPathStart: { x: 680, y: 420, width: 80, height: 60 },
  targetBboxAtCommit: { x: 680, y: 420, width: 80, height: 60 },
  clickPoint: { x: 720, y: 450 },
  cursorPath: [
    { x: 700, y: 450, timeMs: 500 },
    { x: 720, y: 450, timeMs: 900 },
  ],
  mouseDownMs: 1000,
  mouseUpMs: 1005,
};

describe('camera statistics', () => {
  it('measures full target framing and shared click projection', () => {
    const measurement = measureTargetFraming({
      click,
      outputIndex: 30,
      camera,
      viewport,
      contentRect,
    });
    expect(measurement.visibleFraction).toBe(1);
    expect(measurement.clickPointInsideProjectedTarget).toBe(true);
    expect(measurement.targetCenterDistanceFromContentCenterPx).toBe(0);
  });

  it('aggregates motion, compression, and framing', () => {
    const track: CameraTrack = {
      durationMs: 2000,
      viewport,
      transitions: [
        {
          id: 'transition',
          phase: 'transition',
          clickId: click.id,
          startMs: 500,
          endMs: 900,
          from: { zoom: 1, centerCssX: 720, centerCssY: 450 },
          to: { zoom: 1.35, centerCssX: 720, centerCssY: 450 },
          compressed: false,
        },
      ],
      segments: [
        {
          id: 'establish',
          phase: 'establish',
          startMs: 0,
          endMs: 500,
          state: { zoom: 1, centerCssX: 720, centerCssY: 450 },
        },
        {
          id: 'transition',
          phase: 'transition',
          clickId: click.id,
          startMs: 500,
          endMs: 900,
          from: { zoom: 1, centerCssX: 720, centerCssY: 450 },
          to: { zoom: 1.35, centerCssX: 720, centerCssY: 450 },
          compressed: false,
        },
        {
          id: 'hold',
          phase: 'hold',
          startMs: 900,
          endMs: 2000,
          state: { zoom: 1.35, centerCssX: 720, centerCssY: 450 },
        },
      ],
    };
    const framing = measureTargetFraming({ click, outputIndex: 30, camera, viewport, contentRect });
    const statistics = cameraMotionStatistics({
      track,
      states: [{ ...camera, zoom: 1, outputTimestampMs: 0 }, camera],
      framing: [framing],
      viewport,
      contentRect,
    });
    expect(statistics.segmentCount).toBe(3);
    expect(statistics.compressedTransitionCount).toBe(0);
    expect(statistics.targetFraming).toEqual({
      fullyVisibleCount: 1,
      clippedCount: 0,
      maxCenterDistancePx: 0,
    });
  });
});
