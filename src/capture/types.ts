export interface ClockCalibration {
  browserEpochAtDriverZeroMs: number;
  roundTripMs: number;
  sampledAtDriverMs: number;
}

export interface CaptureClockDiagnostics {
  method: 'browser-epoch-to-node-monotonic-midpoint';
  sampleCount: number;
  selectedRoundTripMs: number;
  startupOffsetMs: number;
  endingOffsetMs?: number;
  offsetDeltaMs?: number;
}

export interface CapturedFrameRecord {
  index: number;
  file: string;
  timestampMs: number;
  pixelWidth: number;
  pixelHeight: number;
  pageScaleFactor: number;
  scrollOffsetX: number;
  scrollOffsetY: number;
  offsetTop: number;
  receivedAtMs: number;
}

export interface ScreencastFrameMetadata {
  offsetTop: number;
  pageScaleFactor: number;
  deviceWidth: number;
  deviceHeight: number;
  scrollOffsetX: number;
  scrollOffsetY: number;
  timestamp?: number;
}

export interface QueuedCaptureFrame {
  index: number;
  data: Buffer;
  metadata: ScreencastFrameMetadata;
  timestampMs: number;
  receivedAtMs: number;
}

export interface CaptureQueueDiagnostics {
  received: number;
  acknowledged: number;
  written: number;
  highWaterMark: number;
  overflowCount: number;
  writeFailures: number;
}

export interface ObservedFrameDimensions {
  pixelWidth: number;
  pixelHeight: number;
  frameCount: number;
}

export interface CdpLayoutMetrics {
  layoutViewport: {
    pageX: number;
    pageY: number;
    clientWidth: number;
    clientHeight: number;
  };
  cssLayoutViewport?: {
    pageX: number;
    pageY: number;
    clientWidth: number;
    clientHeight: number;
  };
}

export interface CapturePixelScaleProof {
  method: 'cdp-screencast-css-color-bands';
  passed: boolean;
  probeCssSize: { width: number; height: number };
  expectedPaintedScale: number;
  jpegDimensions: { width: number; height: number };
  samples: Array<{
    x: number;
    y: number;
    expected: number[];
    observed: number[];
    distance: number;
  }>;
  cdpLayoutMetrics: CdpLayoutMetrics;
}

export interface CaptureManifest {
  schemaVersion: 1;
  sourceIdentifier: string;
  scriptHash: string;
  playwrightVersion: string;
  chromiumVersion: string;
  chromiumExecutablePath: string;
  nodeVersion: string;
  operatingSystem: string;
  architecture: string;
  viewport: {
    width: number;
    height: number;
  };
  deviceScaleFactor: number;
  observedBrowserMetrics: {
    innerWidth: number;
    innerHeight: number;
    devicePixelRatio: number;
  };
  captureSurface: {
    method: 'chromium-force-device-scale-factor';
    browserMode: 'headless';
    pixelWidth: number;
    pixelHeight: number;
  };
  chromiumLaunchArguments: string[];
  pixelScaleProof: CapturePixelScaleProof;
  expectedFrameDimensions: {
    pixelWidth: number;
    pixelHeight: number;
  };
  observedFrameDimensions: ObservedFrameDimensions[];
  zoomHeadroomConfirmed: boolean;
  captureStartedAt: string;
  captureDurationMs: number;
  frameCount: number;
  duplicateTimestampCount: number;
  backwardTimestampCount: number;
  clock: CaptureClockDiagnostics;
  queue: CaptureQueueDiagnostics;
  screencast: {
    format: 'jpeg';
    quality: number;
    everyNthFrame: 1;
    maxWidth: number;
    maxHeight: number;
  };
}

export interface DistributionSummary {
  min: number;
  median: number;
  p95: number;
  max: number;
}

export interface CaptureSpikeSummary {
  run: number;
  durationMs: number;
  frameCount: number;
  firstTimestampMs: number;
  lastTimestampMs: number;
  sourcePixelWidth: number;
  sourcePixelHeight: number;
  zoomHeadroomConfirmed: boolean;
  interFrameGapMs: DistributionSummary;
  receiveDelayMs: Omit<DistributionSummary, 'min'>;
  clock: {
    startupRoundTripMs: number;
    startupOffsetMs: number;
    endingOffsetMs: number;
    offsetDeltaMs: number;
  };
  queue: {
    highWaterMark: number;
    overflows: number;
  };
}
