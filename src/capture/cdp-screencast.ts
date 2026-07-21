import { performance } from 'node:perf_hooks';
import { setTimeout } from 'node:timers/promises';
import type { CDPSession } from 'playwright';
import type { CaptureBundleWriter } from './capture-bundle-writer.js';
import { driverMonotonicToBrowserEpochMs } from './clock.js';
import type { ClockCalibration, ScreencastFrameMetadata } from './types.js';

interface ScreencastFramePayload {
  data: string;
  metadata: ScreencastFrameMetadata;
  sessionId: number;
}

export interface ScreencastSettings {
  format: 'jpeg';
  quality: number;
  everyNthFrame: 1;
  maxWidth: number;
  maxHeight: number;
}

export interface CdpScreencastResult {
  captureOriginEpochMs: number;
  duplicateTimestampCount: number;
  backwardTimestampCount: number;
}

export async function runCdpScreencast(options: {
  session: CDPSession;
  writer: CaptureBundleWriter;
  durationMs: number;
  startupCalibration: ClockCalibration;
  settings: ScreencastSettings;
  runDuringCapture?: (captureOriginEpochMs: number) => Promise<void>;
  tailDurationMs?: number;
}): Promise<CdpScreencastResult> {
  const { session, writer, durationMs, startupCalibration, settings } = options;
  let captureOriginEpochMs: number | undefined;
  let previousFrameEpochMs: number | undefined;
  let duplicateTimestampCount = 0;
  let backwardTimestampCount = 0;
  let captureFailure: Error | undefined;
  let rejectCapture: ((error: Error) => void) | undefined;
  const failurePromise = new Promise<never>((_, reject) => {
    rejectCapture = reject;
  });
  const pendingHandlers = new Set<Promise<void>>();
  let resolveCaptureOrigin: ((captureOriginEpochMs: number) => void) | undefined;
  const captureOriginPromise = new Promise<number>((resolve) => {
    resolveCaptureOrigin = resolve;
  });

  function fail(error: unknown): void {
    if (captureFailure) return;
    captureFailure = error instanceof Error ? error : new Error(String(error));
    rejectCapture?.(captureFailure);
  }

  async function handleFrame(payload: ScreencastFramePayload): Promise<void> {
    const receivedDriverMonotonicMs = performance.now();
    writer.markReceived();
    const timestampSeconds = payload.metadata.timestamp;
    if (timestampSeconds === undefined || !Number.isFinite(timestampSeconds)) {
      throw new Error('CDP screencast frame has no finite epoch timestamp');
    }

    const frameEpochMs = timestampSeconds * 1000;
    captureOriginEpochMs ??= frameEpochMs;
    const timestampMs = frameEpochMs - captureOriginEpochMs;
    if (!Number.isFinite(timestampMs) || timestampMs < 0) {
      throw new Error(`CDP frame timestamp normalized to invalid value ${timestampMs}`);
    }
    if (previousFrameEpochMs !== undefined) {
      if (frameEpochMs < previousFrameEpochMs) {
        backwardTimestampCount += 1;
        throw new Error(
          `CDP frame timestamp moved backward by ${previousFrameEpochMs - frameEpochMs}ms`,
        );
      }
      if (frameEpochMs === previousFrameEpochMs) duplicateTimestampCount += 1;
    }
    previousFrameEpochMs = frameEpochMs;

    const frameData = Buffer.from(payload.data, 'base64');
    const receivedEpochMs = driverMonotonicToBrowserEpochMs(
      receivedDriverMonotonicMs,
      startupCalibration,
    );
    writer.enqueue({
      index: writer.diagnostics.received,
      data: frameData,
      metadata: { ...payload.metadata },
      timestampMs,
      receivedAtMs: receivedEpochMs - captureOriginEpochMs,
    });
    if (writer.diagnostics.received === 1) resolveCaptureOrigin?.(captureOriginEpochMs);
    await session.send('Page.screencastFrameAck', { sessionId: payload.sessionId });
    writer.markAcknowledged();
  }

  const listener = (payload: ScreencastFramePayload): void => {
    const handler = handleFrame(payload).catch(fail);
    pendingHandlers.add(handler);
    void handler.finally(() => pendingHandlers.delete(handler));
  };

  session.on('Page.screencastFrame', listener);
  let started = false;
  try {
    await session.send('Page.startScreencast', settings);
    started = true;
    if (options.runDuringCapture) {
      const captureOrigin = await Promise.race([
        captureOriginPromise,
        failurePromise,
        setTimeout(durationMs).then(() => {
          throw new Error('Timed out waiting for the first CDP screencast frame');
        }),
      ]);
      await Promise.race([
        options.runDuringCapture(captureOrigin),
        failurePromise,
        setTimeout(durationMs).then(() => {
          throw new Error(`Capture activity exceeded its ${durationMs}ms limit`);
        }),
      ]);
      await Promise.race([setTimeout(options.tailDurationMs ?? 500), failurePromise]);
    } else {
      await Promise.race([setTimeout(durationMs), failurePromise]);
    }
  } finally {
    if (started) await session.send('Page.stopScreencast').catch(fail);
    session.off('Page.screencastFrame', listener);
    await Promise.all(pendingHandlers);
  }

  if (captureFailure) throw captureFailure;
  if (captureOriginEpochMs === undefined) throw new Error('CDP screencast produced no frames');
  return {
    captureOriginEpochMs,
    duplicateTimestampCount,
    backwardTimestampCount,
  };
}
