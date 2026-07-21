import { exactDistribution } from '../resample/statistics.js';
import type { DistributionStatistics, ResampledFrameRecord } from '../resample/types.js';
import type { ClickTimelineEvent, Point } from '../timeline/types.js';
import type { CursorFrameState, CursorInterpolation } from './cursor-track.js';

export interface CursorLandingMeasurement {
  clickId: string;
  targetTestId: string;
  mouseDownMs: number;
  outputIndex: number;
  outputTimestampMs: number;
  selectedSourceIndex: number;
  selectedSourceTimestampMs: number;
  cursorCssX: number;
  cursorCssY: number;
  clickCssX: number;
  clickCssY: number;
  cursorScreenX: number;
  cursorScreenY: number;
  clickScreenX: number;
  clickScreenY: number;
  errorXOutputPx: number;
  errorYOutputPx: number;
  errorDistanceOutputPx: number;
  cursorInterpolation: Exclude<CursorInterpolation, 'hidden'>;
  outputGridDeltaMs: number;
  sourceToOutputDeltaMs: number;
  sourceToMouseDownDeltaMs: number;
}

export interface CursorLandingStatistics {
  clickCount: number;
  distanceOutputPx: DistributionStatistics;
  absoluteXOutputPx: DistributionStatistics;
  absoluteYOutputPx: DistributionStatistics;
  interpolationAtMouseDown: { exact: number; linear: number; held: number };
  failuresOverOnePixel: number;
  failuresOverTwoPixels: number;
  worstClickId: string;
}

export function measureCursorLanding(options: {
  click: ClickTimelineEvent;
  outputFrame: ResampledFrameRecord;
  cursor: CursorFrameState;
  cursorScreen: Point;
  clickScreen: Point;
}): CursorLandingMeasurement {
  if (
    !options.cursor.visible ||
    options.cursor.cssX === undefined ||
    options.cursor.cssY === undefined ||
    options.cursor.interpolation === 'hidden'
  ) {
    throw new Error(`${options.click.id} has no visible cursor at its mouse-down output frame`);
  }
  const errorXOutputPx = options.cursorScreen.x - options.clickScreen.x;
  const errorYOutputPx = options.cursorScreen.y - options.clickScreen.y;
  return {
    clickId: options.click.id,
    targetTestId:
      typeof options.click.target.value.testId === 'string'
        ? options.click.target.value.testId
        : options.click.target.strategy,
    mouseDownMs: options.click.mouseDownMs,
    outputIndex: options.outputFrame.outputIndex,
    outputTimestampMs: options.outputFrame.outputTimestampMs,
    selectedSourceIndex: options.outputFrame.sourceIndex,
    selectedSourceTimestampMs: options.outputFrame.sourceTimestampMs,
    cursorCssX: options.cursor.cssX,
    cursorCssY: options.cursor.cssY,
    clickCssX: options.click.clickPoint.x,
    clickCssY: options.click.clickPoint.y,
    cursorScreenX: options.cursorScreen.x,
    cursorScreenY: options.cursorScreen.y,
    clickScreenX: options.clickScreen.x,
    clickScreenY: options.clickScreen.y,
    errorXOutputPx,
    errorYOutputPx,
    errorDistanceOutputPx: Math.hypot(errorXOutputPx, errorYOutputPx),
    cursorInterpolation: options.cursor.interpolation,
    outputGridDeltaMs: options.outputFrame.outputTimestampMs - options.click.mouseDownMs,
    sourceToOutputDeltaMs:
      options.outputFrame.sourceTimestampMs - options.outputFrame.outputTimestampMs,
    sourceToMouseDownDeltaMs: options.outputFrame.sourceTimestampMs - options.click.mouseDownMs,
  };
}

export function cursorLandingStatistics(
  measurements: readonly CursorLandingMeasurement[],
): CursorLandingStatistics {
  if (measurements.length === 0) throw new Error('Landing statistics require measurements');
  const distance = measurements.map((measurement) => measurement.errorDistanceOutputPx);
  const worst = measurements.reduce((current, measurement) =>
    measurement.errorDistanceOutputPx > current.errorDistanceOutputPx ? measurement : current,
  );
  const interpolationAtMouseDown = { exact: 0, linear: 0, held: 0 };
  for (const measurement of measurements) {
    interpolationAtMouseDown[measurement.cursorInterpolation] += 1;
  }
  return {
    clickCount: measurements.length,
    distanceOutputPx: exactDistribution(distance),
    absoluteXOutputPx: exactDistribution(
      measurements.map((measurement) => Math.abs(measurement.errorXOutputPx)),
    ),
    absoluteYOutputPx: exactDistribution(
      measurements.map((measurement) => Math.abs(measurement.errorYOutputPx)),
    ),
    interpolationAtMouseDown,
    failuresOverOnePixel: distance.filter((error) => error > 1).length,
    failuresOverTwoPixels: distance.filter((error) => error > 2).length,
    worstClickId: worst.clickId,
  };
}

export function cursorLandingGatePasses(statistics: CursorLandingStatistics): boolean {
  return (
    statistics.clickCount === 30 &&
    statistics.distanceOutputPx.median <= 1 &&
    statistics.distanceOutputPx.p95 <= 2
  );
}
