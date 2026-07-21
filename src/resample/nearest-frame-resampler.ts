import type { CapturedFrameRecord } from '../capture/types.js';
import { OUTPUT_FPS, outputFrameCount, outputTimestampForIndex } from './output-clock.js';
import { StreamingDistribution } from './statistics.js';
import type { ResampledFrameRecord, ResampleStatistics } from './types.js';

export interface ResampleResult {
  sourceFrameCount: number;
  sourceDurationMs: number;
  sourcePixelWidth: number;
  sourcePixelHeight: number;
  outputFrameCount: number;
  outputDurationMs: number;
  statistics: ResampleStatistics;
}

export function selectNearestFrame(
  previous: CapturedFrameRecord,
  next: CapturedFrameRecord | undefined,
  outputTimestampMs: number,
): CapturedFrameRecord {
  if (outputTimestampMs < previous.timestampMs) {
    throw new Error('Previous source frame occurs after the output timestamp');
  }
  if (!next) return previous;
  if (next.timestampMs <= outputTimestampMs) {
    throw new Error('Next source frame must occur after the output timestamp');
  }
  const distanceToPrevious = outputTimestampMs - previous.timestampMs;
  const distanceToNext = next.timestampMs - outputTimestampMs;
  return distanceToPrevious <= distanceToNext ? previous : next;
}

function resampledRecord(
  outputIndex: number,
  outputTimestampMs: number,
  source: CapturedFrameRecord,
): ResampledFrameRecord {
  const signedSourceDeltaMs = source.timestampMs - outputTimestampMs;
  return {
    outputIndex,
    outputTimestampMs,
    sourceIndex: source.index,
    sourceFile: source.file,
    sourceTimestampMs: source.timestampMs,
    signedSourceDeltaMs,
    absoluteSourceDeltaMs: Math.abs(signedSourceDeltaMs),
    relation: signedSourceDeltaMs < 0 ? 'before' : signedSourceDeltaMs > 0 ? 'after' : 'exact',
  };
}

export async function resampleNearestFrames(options: {
  sourceFrames: AsyncIterable<CapturedFrameRecord>;
  onOutputFrame: (record: ResampledFrameRecord) => Promise<void> | void;
  fps?: number;
  onProgress?: () => void;
}): Promise<ResampleResult> {
  const fps = options.fps ?? OUTPUT_FPS;
  const iterator = options.sourceFrames[Symbol.asyncIterator]();
  const firstResult = await iterator.next();
  if (firstResult.done) throw new Error('Resampler requires at least one source frame');
  let previous = firstResult.value;
  let sourceFrameCount = 1;
  let outputIndex = 0;
  let lastOutputTimestampMs = 0;
  let lastSelectedSourceIndex: number | undefined;
  let uniqueSourceFramesSelected = 0;
  let currentReuseRun = 0;
  let maxReuseRun = 0;
  const selectionError = new StreamingDistribution();
  const sourceCadence = new StreamingDistribution();
  const signedSelection = { beforeCount: 0, exactCount: 0, afterCount: 0 };

  const emit = async (next: CapturedFrameRecord | undefined) => {
    const outputTimestampMs = outputTimestampForIndex(outputIndex, fps);
    const selected = selectNearestFrame(previous, next, outputTimestampMs);
    const record = resampledRecord(outputIndex, outputTimestampMs, selected);
    await options.onOutputFrame(record);
    options.onProgress?.();
    selectionError.add(record.absoluteSourceDeltaMs);
    if (record.relation === 'before') signedSelection.beforeCount += 1;
    else if (record.relation === 'after') signedSelection.afterCount += 1;
    else signedSelection.exactCount += 1;
    if (selected.index === lastSelectedSourceIndex) currentReuseRun += 1;
    else {
      uniqueSourceFramesSelected += 1;
      lastSelectedSourceIndex = selected.index;
      currentReuseRun = 1;
    }
    maxReuseRun = Math.max(maxReuseRun, currentReuseRun);
    lastOutputTimestampMs = outputTimestampMs;
    outputIndex += 1;
  };

  while (true) {
    const nextResult = await iterator.next();
    if (nextResult.done) break;
    const next = nextResult.value;
    sourceCadence.add(next.timestampMs - previous.timestampMs);
    sourceFrameCount += 1;
    while (outputTimestampForIndex(outputIndex, fps) < next.timestampMs) {
      await emit(next);
    }
    previous = next;
  }

  while (outputTimestampForIndex(outputIndex, fps) <= previous.timestampMs) {
    await emit(undefined);
  }
  const expectedOutputFrameCount = outputFrameCount(previous.timestampMs, fps);
  if (outputIndex !== expectedOutputFrameCount) {
    throw new Error('Streaming output count differs from the fixed output-clock contract');
  }
  const selectionSummary = selectionError.summary();
  const cadenceSummary =
    sourceFrameCount === 1 ? { min: 0, median: 0, p95: 0, max: 0 } : sourceCadence.summary();
  return {
    sourceFrameCount,
    sourceDurationMs: previous.timestampMs,
    sourcePixelWidth: previous.pixelWidth,
    sourcePixelHeight: previous.pixelHeight,
    outputFrameCount: outputIndex,
    outputDurationMs: lastOutputTimestampMs,
    statistics: {
      selectedSourceErrorMs: {
        median: selectionSummary.median,
        p95: selectionSummary.p95,
        max: selectionSummary.max,
      },
      signedSelection,
      sourceUsage: {
        uniqueSourceFramesSelected,
        sourceFramesSkipped: sourceFrameCount - uniqueSourceFramesSelected,
        outputFramesUsingRepeatedSource: outputIndex - uniqueSourceFramesSelected,
        maxConsecutiveOutputFramesUsingOneSource: maxReuseRun,
      },
      sourceCadenceMs: cadenceSummary,
    },
  };
}
