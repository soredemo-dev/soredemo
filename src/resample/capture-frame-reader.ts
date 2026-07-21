import { constants, createReadStream } from 'node:fs';
import { access, readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createInterface } from 'node:readline';
import type { CapturedFrameRecord } from '../capture/types.js';

const ZERO_TIMESTAMP_TOLERANCE_MS = 1e-6;

export interface CaptureSourceManifest {
  schemaVersion: number;
  frameCount: number;
  captureDurationMs: number;
  viewport: { width: number; height: number };
  deviceScaleFactor: number;
  observedBrowserMetrics: { innerWidth: number; innerHeight: number; devicePixelRatio: number };
  captureSurface: { pixelWidth: number; pixelHeight: number };
  observedFrameDimensions: Array<{
    pixelWidth: number;
    pixelHeight: number;
    frameCount: number;
  }>;
}

export interface CaptureFrameReader {
  manifest: CaptureSourceManifest;
  frames(): AsyncGenerator<CapturedFrameRecord>;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function finiteNumber(record: Record<string, unknown>, key: string): number {
  const value = record[key];
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error(`Frame field ${key} must be a finite number`);
  }
  return value;
}

function positiveInteger(record: Record<string, unknown>, key: string): number {
  const value = finiteNumber(record, key);
  if (!Number.isInteger(value) || value < 1) {
    throw new Error(`Frame field ${key} must be a positive integer`);
  }
  return value;
}

function parseFrame(line: string, lineNumber: number): CapturedFrameRecord {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    throw new Error(`Malformed frames.jsonl record at line ${lineNumber}`);
  }
  if (!isRecord(parsed)) throw new Error(`Frame record at line ${lineNumber} must be an object`);
  const file = parsed.file;
  if (typeof file !== 'string' || file.length === 0) {
    throw new Error(`Frame field file must be a non-empty string at line ${lineNumber}`);
  }
  return {
    index: positiveInteger(parsed, 'index'),
    file,
    timestampMs: finiteNumber(parsed, 'timestampMs'),
    pixelWidth: positiveInteger(parsed, 'pixelWidth'),
    pixelHeight: positiveInteger(parsed, 'pixelHeight'),
    pageScaleFactor: finiteNumber(parsed, 'pageScaleFactor'),
    scrollOffsetX: finiteNumber(parsed, 'scrollOffsetX'),
    scrollOffsetY: finiteNumber(parsed, 'scrollOffsetY'),
    offsetTop: finiteNumber(parsed, 'offsetTop'),
    receivedAtMs: finiteNumber(parsed, 'receivedAtMs'),
  };
}

function parseManifest(value: unknown): CaptureSourceManifest {
  if (!isRecord(value)) throw new Error('Capture manifest must be an object');
  const manifest = value as unknown as CaptureSourceManifest;
  if (
    !Number.isInteger(manifest.schemaVersion) ||
    !Number.isInteger(manifest.frameCount) ||
    manifest.frameCount < 1 ||
    !Number.isFinite(manifest.captureDurationMs)
  ) {
    throw new Error('Capture manifest has invalid schema, frame count, or duration');
  }
  if (
    manifest.viewport?.width !== 1440 ||
    manifest.viewport.height !== 900 ||
    manifest.deviceScaleFactor !== 2 ||
    manifest.observedBrowserMetrics?.innerWidth !== 1440 ||
    manifest.observedBrowserMetrics.innerHeight !== 900 ||
    manifest.observedBrowserMetrics.devicePixelRatio !== 2 ||
    manifest.captureSurface?.pixelWidth !== 2880 ||
    manifest.captureSurface.pixelHeight !== 1800
  ) {
    throw new Error('Capture manifest violates viewport and device-scale invariants');
  }
  if (
    !Array.isArray(manifest.observedFrameDimensions) ||
    manifest.observedFrameDimensions.length !== 1 ||
    manifest.observedFrameDimensions[0]?.pixelWidth !== 2880 ||
    manifest.observedFrameDimensions[0].pixelHeight !== 1800 ||
    manifest.observedFrameDimensions[0].frameCount !== manifest.frameCount
  ) {
    throw new Error('Capture manifest has inconsistent observed frame dimensions');
  }
  return manifest;
}

export async function openCaptureFrameReader(
  captureDirectory: string,
): Promise<CaptureFrameReader> {
  const absoluteCaptureDirectory = resolve(captureDirectory);
  const manifestPath = resolve(absoluteCaptureDirectory, 'manifest.json');
  let manifestValue: unknown;
  try {
    manifestValue = JSON.parse(await readFile(manifestPath, 'utf8'));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Unable to read capture manifest: ${message}`);
  }
  const manifest = parseManifest(manifestValue);
  let consumed = false;

  return {
    manifest,
    async *frames() {
      if (consumed) throw new Error('Capture frame reader can only be consumed once');
      consumed = true;
      const input = createReadStream(resolve(absoluteCaptureDirectory, 'frames.jsonl'), {
        encoding: 'utf8',
      });
      const lines = createInterface({ input, crlfDelay: Number.POSITIVE_INFINITY });
      let previousTimestampMs: number | undefined;
      let expectedIndex = 1;
      let expectedWidth: number | undefined;
      let expectedHeight: number | undefined;

      for await (const line of lines) {
        if (line.length === 0)
          throw new Error(`Empty frames.jsonl record at line ${expectedIndex}`);
        const frame = parseFrame(line, expectedIndex);
        if (frame.index !== expectedIndex) {
          throw new Error(`Expected source frame index ${expectedIndex}, received ${frame.index}`);
        }
        const expectedFile = `frames/${String(expectedIndex).padStart(6, '0')}.jpg`;
        if (frame.file !== expectedFile) {
          throw new Error(`Source frame ${expectedIndex} has unexpected or duplicate filename`);
        }
        if (frame.timestampMs < 0)
          throw new Error(`Source frame ${expectedIndex} has negative time`);
        if (expectedIndex === 1 && Math.abs(frame.timestampMs) > ZERO_TIMESTAMP_TOLERANCE_MS) {
          throw new Error('First source frame timestamp must equal zero within 0.000001ms');
        }
        if (previousTimestampMs !== undefined && frame.timestampMs <= previousTimestampMs) {
          throw new Error(`Source frame ${expectedIndex} timestamp is not strictly increasing`);
        }
        expectedWidth ??= frame.pixelWidth;
        expectedHeight ??= frame.pixelHeight;
        if (
          frame.pixelWidth !== expectedWidth ||
          frame.pixelHeight !== expectedHeight ||
          frame.pixelWidth !== 2880 ||
          frame.pixelHeight !== 1800
        ) {
          throw new Error(`Source frame ${expectedIndex} has inconsistent dimensions`);
        }
        try {
          await access(resolve(absoluteCaptureDirectory, frame.file), constants.R_OK);
        } catch {
          throw new Error(`Source frame file is missing or unreadable: ${frame.file}`);
        }
        previousTimestampMs = frame.timestampMs;
        expectedIndex += 1;
        yield frame;
      }

      const frameCount = expectedIndex - 1;
      if (frameCount < 1) throw new Error('Capture must contain at least one source frame');
      if (frameCount !== manifest.frameCount) {
        throw new Error(
          `Capture manifest frame count ${manifest.frameCount} does not match ${frameCount} records`,
        );
      }
      if (Math.abs((previousTimestampMs ?? 0) - manifest.captureDurationMs) > 1e-6) {
        throw new Error('Capture manifest duration does not match the final source timestamp');
      }
    },
  };
}
