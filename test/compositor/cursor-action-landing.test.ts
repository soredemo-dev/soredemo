import { describe, expect, it } from 'vitest';
import {
  cursorActionFrameRequests,
  cursorActionLandingStatistics,
  firstOutputIndexAtOrAfter,
  measureCursorActionLanding,
  nearestCursorOutputIndex,
} from '../../src/compositor/cursor-action-landing.js';
import type { CameraFrameState } from '../../src/compositor/camera-types.js';
import type { CursorFrameState } from '../../src/compositor/cursor-track.js';
import type { CursorPlacement } from '../../src/compositor/cursor-renderer.js';
import type { ResampledFrameRecord } from '../../src/resample/types.js';
import type {
  ClickTimelineEvent,
  MoveToTimelineEvent,
  TypeTimelineEvent,
} from '../../src/timeline/types.js';

const target = { strategy: 'testId' as const, value: { testId: 'target' } };
const bbox = { x: 40, y: 40, width: 20, height: 20 };
const path = [
  { x: 0, y: 0, timeMs: 100 },
  { x: 50, y: 50, timeMs: 200 },
];

function moveEvent(): MoveToTimelineEvent {
  return {
    id: 'moveTo-001',
    actionIndex: 0,
    kind: 'moveTo',
    startMs: 100,
    endMs: 250,
    target,
    targetBboxAtPathStart: bbox,
    targetBboxAtCommit: bbox,
    destinationPoint: { x: 50, y: 50 },
    cursorPath: path,
    pointerEnterObserved: true,
  };
}

function clickEvent(): ClickTimelineEvent {
  return {
    id: 'click-002',
    actionIndex: 1,
    kind: 'click',
    startMs: 300,
    endMs: 450,
    target,
    targetBboxAtPathStart: bbox,
    targetBboxAtCommit: bbox,
    clickPoint: { x: 50, y: 50 },
    cursorPath: [
      { x: 50, y: 50, timeMs: 300 },
      { x: 50, y: 50, timeMs: 400 },
    ],
    mouseDownMs: 425,
    mouseUpMs: 450,
  };
}

function typeEvent(): TypeTimelineEvent {
  return {
    id: 'type-003',
    actionIndex: 2,
    kind: 'type',
    startMs: 500,
    endMs: 700,
    target,
    targetBboxAtCommit: bbox,
    focusPoint: { x: 50, y: 50 },
    cursorPath: [
      { x: 50, y: 50, timeMs: 500 },
      { x: 50, y: 50, timeMs: 600 },
    ],
    focusMs: 625,
    focusVerified: true,
    textLength: 1,
    clearedExistingValue: false,
    perCharacterDelayMs: 32,
    redacted: false,
  };
}

const frame: ResampledFrameRecord = {
  outputIndex: 6,
  outputTimestampMs: 200,
  sourceIndex: 12,
  sourceFile: 'frames/000012.jpg',
  sourceTimestampMs: 201,
  signedSourceDeltaMs: 1,
  absoluteSourceDeltaMs: 1,
  relation: 'after',
};
const camera: CameraFrameState = {
  outputTimestampMs: 200,
  segmentId: 'camera-hold',
  phase: 'hold',
  zoom: 1,
  centerCssX: 50,
  centerCssY: 50,
  visibleCssRect: { x: 0, y: 0, width: 100, height: 100 },
};
const cursor: CursorFrameState = {
  visible: true,
  cssX: 50,
  cssY: 50,
  screenX: 50,
  screenY: 50,
  activeClickId: 'moveTo-001',
  interpolation: 'held',
};
const placement: CursorPlacement = {
  hotspotScreenX: 50,
  hotspotScreenY: 50,
  drawX: 48,
  drawY: 48,
  width: 30,
  height: 38,
};

describe('cursor action landing', () => {
  it('uses ceiling for completed movement and earlier ties for click mapping', () => {
    expect(firstOutputIndexAtOrAfter(200.1, 30, 100)).toBe(7);
    expect(firstOutputIndexAtOrAfter(200, 30, 100)).toBe(6);
    expect(nearestCursorOutputIndex(50, 30, 100)).toBe(1);
  });

  it('plans proof frames for moveTo, click, and type without click-only filtering', () => {
    const requests = cursorActionFrameRequests([moveEvent(), clickEvent(), typeEvent()], 30, 30);
    expect(new Set(requests.map((request) => request.event.kind))).toEqual(
      new Set(['moveTo', 'click', 'type']),
    );
    expect(requests.find((request) => request.role === 'path-completion')?.outputIndex).toBe(6);
    expect(requests.filter((request) => request.role === 'mouse-down')).toHaveLength(1);
  });

  it('measures the renderer hotspot and completed hold state', () => {
    const event = moveEvent();
    const measurement = measureCursorActionLanding({
      event,
      frame,
      camera,
      cursor,
      cursorPlacement: placement,
      cursorPixelsChanged: 12,
      viewport: { width: 100, height: 100 },
      contentRect: { x: 0, y: 0, width: 100, height: 100 },
      samples: [
        {
          eventId: event.id,
          actionIndex: 0,
          kind: 'moveTo',
          role: 'action-completion',
          outputIndex: 8,
          outputTimestampMs: 266.67,
          cursorCss: { x: 50, y: 50 },
          cursorScreen: { x: 50, y: 50 },
          expectedCss: { x: 50, y: 50 },
          expectedScreen: { x: 50, y: 50 },
          errorDistanceOutputPx: 0,
          activeCursorEventId: event.id,
          interpolation: 'held',
        },
        {
          eventId: event.id,
          actionIndex: 0,
          kind: 'moveTo',
          role: 'final-hold',
          outputIndex: 8,
          outputTimestampMs: 266.67,
          cursorCss: { x: 50, y: 50 },
          cursorScreen: { x: 50, y: 50 },
          expectedCss: { x: 50, y: 50 },
          expectedScreen: { x: 50, y: 50 },
          errorDistanceOutputPx: 0,
          activeCursorEventId: event.id,
          interpolation: 'held',
        },
      ],
    });
    expect(measurement).toMatchObject({
      kind: 'moveTo',
      errorDistanceOutputPx: 0,
      hotspotInsideProjectedTarget: true,
      heldAtActionCompletion: true,
      heldUntilNextCursorAction: true,
    });
    expect(measurement.cursorDrawOrigin).toEqual({ x: 48, y: 48 });
  });

  it('counts every cursor-bearing kind and fails incomplete measurements', () => {
    const valid = measureCursorActionLanding({
      event: moveEvent(),
      frame,
      camera,
      cursor,
      cursorPlacement: placement,
      cursorPixelsChanged: 12,
      viewport: { width: 100, height: 100 },
      contentRect: { x: 0, y: 0, width: 100, height: 100 },
      samples: [],
    });
    const statistics = cursorActionLandingStatistics([
      valid,
      { ...valid, kind: 'click', mouseDownMs: 200 },
      { ...valid, kind: 'type', focusMs: 200, focusVerified: true },
    ]);
    expect(statistics.byKind).toEqual({ moveTo: 1, click: 1, type: 1 });
    expect(statistics.failures).toBe(1);
  });
});
