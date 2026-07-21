export interface ResampledFrameRecord {
  outputIndex: number;
  outputTimestampMs: number;
  sourceIndex: number;
  sourceFile: string;
  sourceTimestampMs: number;
  signedSourceDeltaMs: number;
  absoluteSourceDeltaMs: number;
  relation: 'before' | 'exact' | 'after';
}

export interface DistributionStatistics {
  median: number;
  p95: number;
  max: number;
}

export interface ResampleStatistics {
  selectedSourceErrorMs: DistributionStatistics;
  signedSelection: {
    beforeCount: number;
    exactCount: number;
    afterCount: number;
  };
  sourceUsage: {
    uniqueSourceFramesSelected: number;
    sourceFramesSkipped: number;
    outputFramesUsingRepeatedSource: number;
    maxConsecutiveOutputFramesUsingOneSource: number;
  };
  sourceCadenceMs: {
    min: number;
    median: number;
    p95: number;
    max: number;
  };
}

export interface ResampleManifest {
  schemaVersion: 1;
  sourceCapturePath: string;
  sourceCaptureSchemaVersion: number;
  sourceFrameCount: number;
  sourceDurationMs: number;
  sourcePixelWidth: number;
  sourcePixelHeight: number;
  outputFps: 30;
  outputFrameCount: number;
  outputDurationMs: number;
  selectionPolicy: 'nearest-timestamp';
  tieBreakPolicy: 'earlier-frame';
  statistics: ResampleStatistics;
}

export interface EventFrameMapping {
  eventTimestampMs: number;
  outputIndex: number;
  outputTimestampMs: number;
  signedOutputDeltaMs: number;
  absoluteOutputDeltaMs: number;
  selectedSourceIndex: number;
  selectedSourceTimestampMs: number;
  signedSourceToEventDeltaMs: number;
  absoluteSourceToEventDeltaMs: number;
}

export interface ClickFrameMappingStatistics {
  clickCount: number;
  outputGridErrorMs: DistributionStatistics;
  sourceToOutputErrorMs: DistributionStatistics;
  sourceToMouseDownErrorMs: DistributionStatistics;
  beforeMouseDownCount: number;
  exactMouseDownCount: number;
  afterMouseDownCount: number;
}
