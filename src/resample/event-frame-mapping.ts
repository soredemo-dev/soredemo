import { OUTPUT_FPS, outputTimestampForIndex } from './output-clock.js';
import { exactDistribution } from './statistics.js';
import type {
  ClickFrameMappingStatistics,
  EventFrameMapping,
  ResampledFrameRecord,
} from './types.js';

export function nearestOutputIndex(
  eventTimestampMs: number,
  outputFrameCount: number,
  fps: number = OUTPUT_FPS,
): number {
  if (!Number.isFinite(eventTimestampMs)) throw new Error('Event timestamp must be finite');
  if (!Number.isInteger(outputFrameCount) || outputFrameCount < 1) {
    throw new Error('Output frame count must be a positive integer');
  }
  const idealIndex = (eventTimestampMs * fps) / 1000;
  const lowerIndex = Math.floor(idealIndex);
  const fraction = idealIndex - lowerIndex;
  const tieTolerance = Number.EPSILON * Math.max(1, Math.abs(idealIndex)) * 4;
  const nearestIndex = fraction <= 0.5 + tieTolerance ? lowerIndex : lowerIndex + 1;
  return Math.min(outputFrameCount - 1, Math.max(0, nearestIndex));
}

export function mapEventToOutputFrame(options: {
  eventTimestampMs: number;
  outputFrameCount: number;
  selectedFrame: ResampledFrameRecord;
  fps?: number;
}): EventFrameMapping {
  const fps = options.fps ?? OUTPUT_FPS;
  const outputIndex = nearestOutputIndex(options.eventTimestampMs, options.outputFrameCount, fps);
  if (options.selectedFrame.outputIndex !== outputIndex) {
    throw new Error('Selected resample record does not match the event output index');
  }
  const outputTimestampMs = outputTimestampForIndex(outputIndex, fps);
  const signedOutputDeltaMs = outputTimestampMs - options.eventTimestampMs;
  const signedSourceToEventDeltaMs =
    options.selectedFrame.sourceTimestampMs - options.eventTimestampMs;
  return {
    eventTimestampMs: options.eventTimestampMs,
    outputIndex,
    outputTimestampMs,
    signedOutputDeltaMs,
    absoluteOutputDeltaMs: Math.abs(signedOutputDeltaMs),
    selectedSourceIndex: options.selectedFrame.sourceIndex,
    selectedSourceTimestampMs: options.selectedFrame.sourceTimestampMs,
    signedSourceToEventDeltaMs,
    absoluteSourceToEventDeltaMs: Math.abs(signedSourceToEventDeltaMs),
  };
}

export function clickFrameMappingStatistics(
  mappings: EventFrameMapping[],
  selectedFrames: ResampledFrameRecord[],
): ClickFrameMappingStatistics {
  if (mappings.length === 0 || mappings.length !== selectedFrames.length) {
    throw new Error('Click mapping statistics require aligned non-empty inputs');
  }
  let beforeMouseDownCount = 0;
  let exactMouseDownCount = 0;
  let afterMouseDownCount = 0;
  for (const mapping of mappings) {
    if (mapping.signedSourceToEventDeltaMs < 0) beforeMouseDownCount += 1;
    else if (mapping.signedSourceToEventDeltaMs > 0) afterMouseDownCount += 1;
    else exactMouseDownCount += 1;
  }
  return {
    clickCount: mappings.length,
    outputGridErrorMs: exactDistribution(mappings.map((mapping) => mapping.absoluteOutputDeltaMs)),
    sourceToOutputErrorMs: exactDistribution(
      selectedFrames.map((frame) => frame.absoluteSourceDeltaMs),
    ),
    sourceToMouseDownErrorMs: exactDistribution(
      mappings.map((mapping) => mapping.absoluteSourceToEventDeltaMs),
    ),
    beforeMouseDownCount,
    exactMouseDownCount,
    afterMouseDownCount,
  };
}
