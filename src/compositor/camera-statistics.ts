import { exactDistribution } from '../resample/statistics.js';
import type { ClickTimelineEvent, Point } from '../timeline/types.js';
import {
  pointInsideRect,
  projectCssPoint,
  projectCssRect,
  visibleFraction,
} from './camera-projection.js';
import type {
  CameraFrameState,
  CameraTrack,
  Size,
  TargetFramingMeasurement,
} from './camera-types.js';
import type { Rect } from './types.js';

export interface CameraMotionStatistics {
  segmentCount: number;
  transitionCount: number;
  compressedTransitionCount: number;
  zoom: ReturnType<typeof exactDistribution>;
  perFrameCenterMovementPx: ReturnType<typeof exactDistribution>;
  perFrameZoomDelta: ReturnType<typeof exactDistribution>;
  targetFraming: {
    fullyVisibleCount: number;
    clippedCount: number;
    maxCenterDistancePx: number;
  };
  longestHoldMs: number;
  shortestHoldMs: number;
}

export function measureTargetFraming(options: {
  click: ClickTimelineEvent;
  outputIndex: number;
  camera: CameraFrameState;
  viewport: Size;
  contentRect: Rect;
}): TargetFramingMeasurement {
  const targetOutputRect = projectCssRect(
    options.click.targetBboxAtCommit,
    options.camera,
    options.viewport,
    options.contentRect,
  );
  const clickOutput = projectCssPoint(
    options.click.clickPoint,
    options.camera,
    options.viewport,
    options.contentRect,
  );
  const targetCenter: Point = {
    x: targetOutputRect.x + targetOutputRect.width / 2,
    y: targetOutputRect.y + targetOutputRect.height / 2,
  };
  const contentCenter: Point = {
    x: options.contentRect.x + options.contentRect.width / 2,
    y: options.contentRect.y + options.contentRect.height / 2,
  };
  return {
    clickId: options.click.id,
    targetTestId:
      typeof options.click.target.value.testId === 'string'
        ? options.click.target.value.testId
        : options.click.target.strategy,
    outputIndex: options.outputIndex,
    zoom: options.camera.zoom,
    cameraCenterCssX: options.camera.centerCssX,
    cameraCenterCssY: options.camera.centerCssY,
    targetOutputRect,
    visibleFraction: visibleFraction(targetOutputRect, options.contentRect),
    clickPointInsideProjectedTarget: pointInsideRect(clickOutput, targetOutputRect),
    targetCenterDistanceFromContentCenterPx: Math.hypot(
      targetCenter.x - contentCenter.x,
      targetCenter.y - contentCenter.y,
    ),
  };
}

export function cameraMotionStatistics(options: {
  track: CameraTrack;
  states: readonly CameraFrameState[];
  framing: readonly TargetFramingMeasurement[];
  viewport: Size;
  contentRect: Rect;
}): CameraMotionStatistics {
  if (options.states.length === 0) throw new Error('Camera statistics require frame states');
  const movement: number[] = [];
  const zoomDelta: number[] = [];
  for (let index = 1; index < options.states.length; index += 1) {
    const previous = options.states[index - 1];
    const current = options.states[index];
    if (!previous || !current) continue;
    movement.push(
      Math.hypot(
        ((current.centerCssX - previous.centerCssX) * options.contentRect.width) /
          options.viewport.width,
        ((current.centerCssY - previous.centerCssY) * options.contentRect.height) /
          options.viewport.height,
      ),
    );
    zoomDelta.push(Math.abs(current.zoom - previous.zoom));
  }
  const holds = options.track.segments
    .filter((segment) => segment.phase !== 'transition')
    .map((segment) => segment.endMs - segment.startMs);
  const centerDistances = options.framing.map(
    (measurement) => measurement.targetCenterDistanceFromContentCenterPx,
  );
  return {
    segmentCount: options.track.segments.length,
    transitionCount: options.track.transitions.length,
    compressedTransitionCount: options.track.transitions.filter((segment) => segment.compressed)
      .length,
    zoom: exactDistribution(options.states.map((state) => state.zoom)),
    perFrameCenterMovementPx: exactDistribution(movement.length ? movement : [0]),
    perFrameZoomDelta: exactDistribution(zoomDelta.length ? zoomDelta : [0]),
    targetFraming: {
      fullyVisibleCount: options.framing.filter(
        (measurement) => Math.abs(measurement.visibleFraction - 1) <= 1e-7,
      ).length,
      clippedCount: options.framing.filter((measurement) => measurement.visibleFraction < 1 - 1e-7)
        .length,
      maxCenterDistancePx: centerDistances.length ? Math.max(...centerDistances) : 0,
    },
    longestHoldMs: holds.length ? Math.max(...holds) : 0,
    shortestHoldMs: holds.length ? Math.min(...holds) : 0,
  };
}
