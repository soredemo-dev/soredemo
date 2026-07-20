import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { arch, platform, release } from 'node:os';
import { chromium } from 'playwright';
import { CaptureBundleWriter } from './capture-bundle-writer.js';
import { runCdpScreencast, type ScreencastSettings } from './cdp-screencast.js';
import { calibrateBrowserEpoch } from './clock.js';
import type {
  CapturedFrameRecord,
  CaptureManifest,
  CaptureSpikeSummary,
  DistributionSummary,
  ObservedFrameDimensions,
} from './types.js';

const require = createRequire(import.meta.url);

export interface CaptureSessionOptions {
  url: string;
  outputDirectory: string;
  durationMs: number;
  sourceIdentifier: string;
  scriptHash: string;
  viewport?: { width: number; height: number };
  deviceScaleFactor?: number;
  queueLimit?: number;
  clockSampleCount?: number;
}

export interface CaptureSessionResult {
  manifest: CaptureManifest;
  records: CapturedFrameRecord[];
}

function distribution(values: number[]): DistributionSummary {
  if (values.length === 0) return { min: 0, median: 0, p95: 0, max: 0 };
  const sorted = [...values].sort((left, right) => left - right);
  const percentile = (fraction: number): number => {
    const position = (sorted.length - 1) * fraction;
    const lower = Math.floor(position);
    const upper = Math.ceil(position);
    const lowerValue = sorted[lower] ?? 0;
    const upperValue = sorted[upper] ?? lowerValue;
    return lowerValue + (upperValue - lowerValue) * (position - lower);
  };
  return {
    min: sorted[0] ?? 0,
    median: percentile(0.5),
    p95: percentile(0.95),
    max: sorted.at(-1) ?? 0,
  };
}

function observedDimensions(records: CapturedFrameRecord[]): ObservedFrameDimensions[] {
  const counts = new Map<string, ObservedFrameDimensions>();
  for (const record of records) {
    const key = `${record.pixelWidth}x${record.pixelHeight}`;
    const current = counts.get(key);
    if (current) current.frameCount += 1;
    else {
      counts.set(key, {
        pixelWidth: record.pixelWidth,
        pixelHeight: record.pixelHeight,
        frameCount: 1,
      });
    }
  }
  return [...counts.values()].sort(
    (left, right) => left.pixelWidth - right.pixelWidth || left.pixelHeight - right.pixelHeight,
  );
}

async function playwrightVersion(): Promise<string> {
  const packagePath = require.resolve('playwright/package.json');
  const packageJson = JSON.parse(await readFile(packagePath, 'utf8')) as { version: string };
  return packageJson.version;
}

export async function captureSession(
  options: CaptureSessionOptions,
): Promise<CaptureSessionResult> {
  const viewport = options.viewport ?? { width: 1440, height: 900 };
  const deviceScaleFactor = options.deviceScaleFactor ?? 2;
  const expectedFrameDimensions = {
    pixelWidth: viewport.width * deviceScaleFactor,
    pixelHeight: viewport.height * deviceScaleFactor,
  };
  const settings: ScreencastSettings = {
    format: 'jpeg',
    quality: 90,
    everyNthFrame: 1,
    maxWidth: expectedFrameDimensions.pixelWidth,
    maxHeight: expectedFrameDimensions.pixelHeight,
  };
  const writer = await CaptureBundleWriter.create({
    outputDirectory: options.outputDirectory,
    queueLimit: options.queueLimit ?? 120,
  });
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport, deviceScaleFactor });
  const page = await context.newPage();
  let session: Awaited<ReturnType<typeof context.newCDPSession>> | undefined;

  try {
    await page.goto(options.url, { waitUntil: 'networkidle' });
    await page.locator('[data-capture-probe]').waitFor({ state: 'visible' });
    const sampleBrowserEpochMs = () =>
      page.evaluate(() => performance.timeOrigin + performance.now());
    const sampleCount = options.clockSampleCount ?? 9;
    const startupCalibration = await calibrateBrowserEpoch(sampleBrowserEpochMs, sampleCount);
    session = await context.newCDPSession(page);
    await session.send('Page.enable');
    await session.send('Emulation.setDeviceMetricsOverride', {
      width: viewport.width,
      height: viewport.height,
      deviceScaleFactor,
      mobile: false,
      screenWidth: viewport.width,
      screenHeight: viewport.height,
      dontSetVisibleSize: true,
    });
    await session.send('Emulation.setVisibleSize', {
      width: expectedFrameDimensions.pixelWidth,
      height: expectedFrameDimensions.pixelHeight,
    });
    const observedBrowserMetrics = await page.evaluate(() => ({
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      devicePixelRatio: window.devicePixelRatio,
    }));
    if (
      observedBrowserMetrics.innerWidth !== viewport.width ||
      observedBrowserMetrics.innerHeight !== viewport.height ||
      observedBrowserMetrics.devicePixelRatio !== deviceScaleFactor
    ) {
      throw new Error(
        `Browser metrics do not match the capture contract: ${JSON.stringify(observedBrowserMetrics)}`,
      );
    }
    const cdpResult = await runCdpScreencast({
      session,
      writer,
      durationMs: options.durationMs,
      startupCalibration,
      settings,
    });
    const endingCalibration = await calibrateBrowserEpoch(sampleBrowserEpochMs, sampleCount);
    await writer.close();

    const records = [...writer.records];
    const dimensions = observedDimensions(records);
    const zoomHeadroomConfirmed =
      dimensions.length === 1 &&
      dimensions[0]?.pixelWidth === expectedFrameDimensions.pixelWidth &&
      dimensions[0]?.pixelHeight === expectedFrameDimensions.pixelHeight;
    const lastTimestampMs = records.at(-1)?.timestampMs ?? 0;
    const manifest: CaptureManifest = {
      schemaVersion: 1,
      sourceIdentifier: options.sourceIdentifier,
      scriptHash: options.scriptHash,
      playwrightVersion: await playwrightVersion(),
      chromiumVersion: browser.version(),
      chromiumExecutablePath: chromium.executablePath(),
      nodeVersion: process.version,
      operatingSystem: `${platform()} ${release()}`,
      architecture: arch(),
      viewport,
      deviceScaleFactor,
      observedBrowserMetrics,
      captureSurface: {
        method: 'cdp-explicit-visible-size',
        pixelWidth: expectedFrameDimensions.pixelWidth,
        pixelHeight: expectedFrameDimensions.pixelHeight,
      },
      expectedFrameDimensions,
      observedFrameDimensions: dimensions,
      zoomHeadroomConfirmed,
      captureStartedAt: new Date(cdpResult.captureOriginEpochMs).toISOString(),
      captureDurationMs: lastTimestampMs,
      frameCount: records.length,
      duplicateTimestampCount: cdpResult.duplicateTimestampCount,
      backwardTimestampCount: cdpResult.backwardTimestampCount,
      clock: {
        method: 'browser-epoch-to-node-monotonic-midpoint',
        sampleCount,
        selectedRoundTripMs: startupCalibration.roundTripMs,
        startupOffsetMs: startupCalibration.browserEpochAtDriverZeroMs,
        endingOffsetMs: endingCalibration.browserEpochAtDriverZeroMs,
        offsetDeltaMs:
          endingCalibration.browserEpochAtDriverZeroMs -
          startupCalibration.browserEpochAtDriverZeroMs,
      },
      queue: { ...writer.diagnostics },
      screencast: settings,
    };
    await writer.writeManifest(manifest);

    if (!zoomHeadroomConfirmed) {
      throw new Error(
        `Expected ${expectedFrameDimensions.pixelWidth}x${expectedFrameDimensions.pixelHeight} JPEG frames, observed ${dimensions.map((value) => `${value.pixelWidth}x${value.pixelHeight}`).join(', ')}`,
      );
    }
    if (
      manifest.queue.received !== manifest.queue.acknowledged ||
      manifest.queue.acknowledged !== manifest.queue.written ||
      manifest.queue.overflowCount !== 0 ||
      manifest.queue.writeFailures !== 0
    ) {
      throw new Error('Capture queue counters do not describe a lossless run');
    }

    return { manifest, records };
  } finally {
    await writer.close().catch(() => undefined);
    await session?.detach().catch(() => undefined);
    await context.close().catch(() => undefined);
    await browser.close().catch(() => undefined);
  }
}

export function summarizeCapture(run: number, result: CaptureSessionResult): CaptureSpikeSummary {
  const { manifest, records } = result;
  const gaps = records.slice(1).flatMap((record, index) => {
    const previous = records[index];
    return previous ? [record.timestampMs - previous.timestampMs] : [];
  });
  const delays = records.map((record) => record.receivedAtMs - record.timestampMs);
  const gapStats = distribution(gaps);
  const delayStats = distribution(delays);
  const dimensions = manifest.observedFrameDimensions[0];
  if (
    !dimensions ||
    manifest.clock.endingOffsetMs === undefined ||
    manifest.clock.offsetDeltaMs === undefined
  ) {
    throw new Error('Capture manifest is missing spike summary diagnostics');
  }

  return {
    run,
    durationMs: manifest.captureDurationMs,
    frameCount: manifest.frameCount,
    firstTimestampMs: records[0]?.timestampMs ?? 0,
    lastTimestampMs: records.at(-1)?.timestampMs ?? 0,
    sourcePixelWidth: dimensions.pixelWidth,
    sourcePixelHeight: dimensions.pixelHeight,
    zoomHeadroomConfirmed: manifest.zoomHeadroomConfirmed,
    interFrameGapMs: gapStats,
    receiveDelayMs: {
      median: delayStats.median,
      p95: delayStats.p95,
      max: delayStats.max,
    },
    clock: {
      startupRoundTripMs: manifest.clock.selectedRoundTripMs,
      startupOffsetMs: manifest.clock.startupOffsetMs,
      endingOffsetMs: manifest.clock.endingOffsetMs,
      offsetDeltaMs: manifest.clock.offsetDeltaMs,
    },
    queue: {
      highWaterMark: manifest.queue.highWaterMark,
      overflows: manifest.queue.overflowCount,
    },
  };
}
