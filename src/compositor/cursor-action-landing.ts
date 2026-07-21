import type { ResampledFrameRecord } from '../resample/types.js';
import type {
  ClickTimelineEvent,
  MoveToTimelineEvent,
  Point,
  ResolvedTarget,
  TimelineEvent,
  TypeTimelineEvent,
} from '../timeline/types.js';
import { projectCssPoint, projectCssRect, pointInsideRect } from './camera-projection.js';
import type { CameraFrameState, Size } from './camera-types.js';
import type { CursorFrameState } from './cursor-track.js';
import type { CursorPlacement } from './cursor-renderer.js';
import type { Rect } from './types.js';

export type CursorBearingTimelineEvent =
  | MoveToTimelineEvent
  | ClickTimelineEvent
  | TypeTimelineEvent;

export type CursorProofFrameRole =
  | 'movement-midpoint'
  | 'path-completion'
  | 'action-completion'
  | 'final-hold'
  | 'mouse-down';

export interface CursorActionFrameRequest {
  event: CursorBearingTimelineEvent;
  outputIndex: number;
  role: CursorProofFrameRole;
}

export interface CursorActionFrameSample {
  eventId: string;
  actionIndex: number;
  kind: CursorBearingTimelineEvent['kind'];
  role: CursorProofFrameRole;
  outputIndex: number;
  outputTimestampMs: number;
  cursorCss: Point;
  cursorScreen: Point;
  expectedCss: Point;
  expectedScreen: Point;
  errorDistanceOutputPx: number;
  activeCursorEventId?: string;
  interpolation: CursorFrameState['interpolation'];
}

interface CursorActionLandingBase {
  eventId: string;
  actionIndex: number;
  kind: CursorBearingTimelineEvent['kind'];
  target: ResolvedTarget;
  targetBboxCss: Rect;
  projectedTargetBbox: Rect;
  expectedCss: Point;
  expectedScreen: Point;
  outputIndex: number;
  outputTimestampMs: number;
  sourceIndex: number;
  sourceTimestampMs: number;
  camera: CameraFrameState;
  cursorCss: Point;
  cursorScreen: Point;
  cursorDrawOrigin: Point;
  cursorRenderedSize: Size;
  cursorRenderedHotspot: Point;
  cursorInterpolation: Exclude<CursorFrameState['interpolation'], 'hidden'>;
  activeCursorEventId?: string;
  errorXOutputPx: number;
  errorYOutputPx: number;
  errorDistanceOutputPx: number;
  hotspotInsideProjectedTarget: boolean;
  cursorPixelsChanged: number;
}

export interface MoveToLandingMeasurement extends CursorActionLandingBase {
  kind: 'moveTo';
  pointerEnterObserved: boolean;
  heldAtActionCompletion: boolean;
  heldUntilNextCursorAction: boolean;
}

export interface ClickLandingMeasurement extends CursorActionLandingBase {
  kind: 'click';
  mouseDownMs: number;
}

export interface TypeFocusLandingMeasurement extends CursorActionLandingBase {
  kind: 'type';
  focusMs: number;
  focusVerified: boolean;
}

export type CursorActionLandingMeasurement =
  | MoveToLandingMeasurement
  | ClickLandingMeasurement
  | TypeFocusLandingMeasurement;

export interface CursorActionLandingStatistics {
  total: number;
  byKind: { moveTo: number; click: number; type: number };
  errorDistanceOutputPx: { median: number; p95: number; max: number };
  insideTargetCount: number;
  failures: number;
}

const EPSILON = 1e-9;

export function firstOutputIndexAtOrAfter(
  timestampMs: number,
  fps: number,
  outputFrameCount: number,
): number {
  validateGrid(timestampMs, fps, outputFrameCount);
  return Math.min(outputFrameCount - 1, Math.max(0, Math.ceil((timestampMs * fps) / 1000 - EPSILON)));
}

export function nearestCursorOutputIndex(
  timestampMs: number,
  fps: number,
  outputFrameCount: number,
): number {
  validateGrid(timestampMs, fps, outputFrameCount);
  const ideal = (timestampMs * fps) / 1000;
  const lower = Math.floor(ideal);
  const upper = Math.ceil(ideal);
  const chosen = ideal - lower <= upper - ideal ? lower : upper;
  return Math.min(outputFrameCount - 1, Math.max(0, chosen));
}

export function cursorActionFrameRequests(
  events: readonly TimelineEvent[],
  fps: number,
  outputFrameCount: number,
): CursorActionFrameRequest[] {
  const cursorEvents = events.filter(isCursorBearingEvent);
  const requests: CursorActionFrameRequest[] = [];
  for (const [index, event] of cursorEvents.entries()) {
    const first = event.cursorPath[0];
    const final = event.cursorPath.at(-1);
    if (!first || !final) throw new Error(`${event.id} has no cursor path`);
    requests.push({
      event,
      outputIndex: nearestCursorOutputIndex((first.timeMs + final.timeMs) / 2, fps, outputFrameCount),
      role: 'movement-midpoint',
    });
    if (event.kind === 'click') {
      requests.push({
        event,
        outputIndex: nearestCursorOutputIndex(event.mouseDownMs, fps, outputFrameCount),
        role: 'mouse-down',
      });
    } else {
      requests.push({
        event,
        outputIndex: firstOutputIndexAtOrAfter(final.timeMs, fps, outputFrameCount),
        role: 'path-completion',
      });
    }
    requests.push({
      event,
      outputIndex: firstOutputIndexAtOrAfter(event.endMs, fps, outputFrameCount),
      role: 'action-completion',
    });
    const next = cursorEvents[index + 1];
    const lastHeldIndex = next
      ? Math.max(
          0,
          firstOutputIndexAtOrAfter(next.cursorPath[0]?.timeMs ?? next.startMs, fps, outputFrameCount) -
            1,
        )
      : outputFrameCount - 1;
    requests.push({ event, outputIndex: lastHeldIndex, role: 'final-hold' });
  }
  return requests;
}

export function measureCursorActionLanding(options: {
  event: CursorBearingTimelineEvent;
  frame: ResampledFrameRecord;
  camera: CameraFrameState;
  cursor: CursorFrameState;
  cursorPlacement: CursorPlacement;
  cursorPixelsChanged: number;
  viewport: Size;
  contentRect: Rect;
  samples: readonly CursorActionFrameSample[];
}): CursorActionLandingMeasurement {
  const { event, frame, camera, cursor, cursorPlacement } = options;
  if (!cursor.visible || cursor.cssX === undefined || cursor.cssY === undefined) {
    throw new Error(`${event.id} has no visible cursor at its landing frame`);
  }
  const expectedCss = expectedPoint(event);
  const expectedScreen = projectCssPoint(expectedCss, camera, options.viewport, options.contentRect);
  const cursorScreen = {
    x: cursorPlacement.hotspotScreenX,
    y: cursorPlacement.hotspotScreenY,
  };
  const errorXOutputPx = cursorScreen.x - expectedScreen.x;
  const errorYOutputPx = cursorScreen.y - expectedScreen.y;
  const targetBboxCss = event.targetBboxAtCommit;
  const projectedTargetBbox = projectCssRect(
    targetBboxCss,
    camera,
    options.viewport,
    options.contentRect,
  );
  const base: CursorActionLandingBase = {
    eventId: event.id,
    actionIndex: event.actionIndex ?? -1,
    kind: event.kind,
    target: event.target,
    targetBboxCss,
    projectedTargetBbox,
    expectedCss,
    expectedScreen,
    outputIndex: frame.outputIndex,
    outputTimestampMs: frame.outputTimestampMs,
    sourceIndex: frame.sourceIndex,
    sourceTimestampMs: frame.sourceTimestampMs,
    camera,
    cursorCss: { x: cursor.cssX, y: cursor.cssY },
    cursorScreen,
    cursorDrawOrigin: { x: cursorPlacement.drawX, y: cursorPlacement.drawY },
    cursorRenderedSize: { width: cursorPlacement.width, height: cursorPlacement.height },
    cursorRenderedHotspot: {
      x: cursorScreen.x - cursorPlacement.drawX,
      y: cursorScreen.y - cursorPlacement.drawY,
    },
    cursorInterpolation: cursor.interpolation as Exclude<CursorFrameState['interpolation'], 'hidden'>,
    ...(cursor.activeClickId ? { activeCursorEventId: cursor.activeClickId } : {}),
    errorXOutputPx,
    errorYOutputPx,
    errorDistanceOutputPx: Math.hypot(errorXOutputPx, errorYOutputPx),
    hotspotInsideProjectedTarget: pointInsideRect(cursorScreen, projectedTargetBbox),
    cursorPixelsChanged: options.cursorPixelsChanged,
  };
  if (event.kind === 'moveTo') {
    return {
      ...base,
      kind: 'moveTo',
      pointerEnterObserved: event.pointerEnterObserved,
      heldAtActionCompletion: heldAt(options.samples, event, 'action-completion'),
      heldUntilNextCursorAction: heldAt(options.samples, event, 'final-hold'),
    };
  }
  if (event.kind === 'click') return { ...base, kind: 'click', mouseDownMs: event.mouseDownMs };
  return {
    ...base,
    kind: 'type',
    focusMs: event.focusMs,
    focusVerified: event.focusVerified,
  };
}

export function cursorActionLandingStatistics(
  measurements: readonly CursorActionLandingMeasurement[],
): CursorActionLandingStatistics {
  const errors = measurements.map((measurement) => measurement.errorDistanceOutputPx);
  return {
    total: measurements.length,
    byKind: {
      moveTo: measurements.filter((measurement) => measurement.kind === 'moveTo').length,
      click: measurements.filter((measurement) => measurement.kind === 'click').length,
      type: measurements.filter((measurement) => measurement.kind === 'type').length,
    },
    errorDistanceOutputPx: distribution(errors),
    insideTargetCount: measurements.filter((measurement) => measurement.hotspotInsideProjectedTarget)
      .length,
    failures: measurements.filter(
      (measurement) =>
        measurement.errorDistanceOutputPx > 2 ||
        !measurement.hotspotInsideProjectedTarget ||
        measurement.cursorPixelsChanged < 1 ||
        (measurement.kind === 'moveTo' &&
          (!measurement.pointerEnterObserved ||
            !measurement.heldAtActionCompletion ||
            !measurement.heldUntilNextCursorAction)) ||
        (measurement.kind === 'type' && !measurement.focusVerified),
    ).length,
  };
}

export function cursorFrameSample(options: {
  request: CursorActionFrameRequest;
  frame: ResampledFrameRecord;
  cursor: CursorFrameState;
  cursorPlacement: CursorPlacement;
  camera: CameraFrameState;
  viewport: Size;
  contentRect: Rect;
}): CursorActionFrameSample {
  const { event } = options.request;
  if (!options.cursor.visible || options.cursor.cssX === undefined || options.cursor.cssY === undefined) {
    throw new Error(`${event.id} has no visible cursor for ${options.request.role}`);
  }
  const expectedCss = expectedPoint(event);
  const expectedScreen = projectCssPoint(
    expectedCss,
    options.camera,
    options.viewport,
    options.contentRect,
  );
  const cursorScreen = {
    x: options.cursorPlacement.hotspotScreenX,
    y: options.cursorPlacement.hotspotScreenY,
  };
  return {
    eventId: event.id,
    actionIndex: event.actionIndex ?? -1,
    kind: event.kind,
    role: options.request.role,
    outputIndex: options.frame.outputIndex,
    outputTimestampMs: options.frame.outputTimestampMs,
    cursorCss: { x: options.cursor.cssX, y: options.cursor.cssY },
    cursorScreen,
    expectedCss,
    expectedScreen,
    errorDistanceOutputPx: Math.hypot(
      cursorScreen.x - expectedScreen.x,
      cursorScreen.y - expectedScreen.y,
    ),
    ...(options.cursor.activeClickId ? { activeCursorEventId: options.cursor.activeClickId } : {}),
    interpolation: options.cursor.interpolation,
  };
}

export function isCursorBearingEvent(event: TimelineEvent): event is CursorBearingTimelineEvent {
  return event.kind === 'moveTo' || event.kind === 'click' || event.kind === 'type';
}

function expectedPoint(event: CursorBearingTimelineEvent): Point {
  if (event.kind === 'moveTo') return event.destinationPoint;
  if (event.kind === 'click') return event.clickPoint;
  return event.focusPoint;
}

function heldAt(
  samples: readonly CursorActionFrameSample[],
  event: MoveToTimelineEvent,
  role: 'action-completion' | 'final-hold',
): boolean {
  const sample = samples.find((candidate) => candidate.eventId === event.id && candidate.role === role);
  return Boolean(
    sample &&
      sample.activeCursorEventId === event.id &&
      sample.errorDistanceOutputPx <= 2 &&
      (sample.interpolation === 'held' || sample.interpolation === 'exact'),
  );
}

function validateGrid(timestampMs: number, fps: number, outputFrameCount: number): void {
  if (!Number.isFinite(timestampMs) || timestampMs < 0) throw new Error('Timestamp must be finite');
  if (!Number.isFinite(fps) || fps <= 0) throw new Error('FPS must be positive');
  if (!Number.isInteger(outputFrameCount) || outputFrameCount < 1) {
    throw new Error('Output frame count must be positive');
  }
}

function distribution(values: readonly number[]): { median: number; p95: number; max: number } {
  if (values.length === 0) return { median: 0, p95: 0, max: 0 };
  const sorted = [...values].sort((left, right) => left - right);
  const percentile = (fraction: number): number => {
    const position = (sorted.length - 1) * fraction;
    const lower = Math.floor(position);
    const upper = Math.ceil(position);
    const left = sorted[lower] ?? 0;
    const right = sorted[upper] ?? left;
    return left + (right - left) * (position - lower);
  };
  return { median: percentile(0.5), p95: percentile(0.95), max: sorted.at(-1) ?? 0 };
}
