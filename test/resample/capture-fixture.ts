import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { CapturedFrameRecord } from '../../src/capture/types.js';

export function sourceFrame(
  index: number,
  timestampMs: number,
  overrides: Partial<CapturedFrameRecord> = {},
): CapturedFrameRecord {
  return {
    index,
    file: `frames/${String(index).padStart(6, '0')}.jpg`,
    timestampMs,
    pixelWidth: 2880,
    pixelHeight: 1800,
    pageScaleFactor: 1,
    scrollOffsetX: 0,
    scrollOffsetY: 0,
    offsetTop: 0,
    receivedAtMs: timestampMs + 2,
    ...overrides,
  };
}

export async function writeCaptureFixture(options: {
  directory: string;
  records: CapturedFrameRecord[];
  manifestFrameCount?: number;
  manifestDurationMs?: number;
  rawJsonl?: string;
  omitFiles?: string[];
}): Promise<void> {
  await mkdir(join(options.directory, 'frames'), { recursive: true });
  const frameCount = options.manifestFrameCount ?? options.records.length;
  const durationMs = options.manifestDurationMs ?? options.records.at(-1)?.timestampMs ?? 0;
  await writeFile(
    join(options.directory, 'manifest.json'),
    `${JSON.stringify({
      schemaVersion: 1,
      frameCount,
      captureDurationMs: durationMs,
      viewport: { width: 1440, height: 900 },
      deviceScaleFactor: 2,
      observedBrowserMetrics: { innerWidth: 1440, innerHeight: 900, devicePixelRatio: 2 },
      captureSurface: { pixelWidth: 2880, pixelHeight: 1800 },
      observedFrameDimensions: [{ pixelWidth: 2880, pixelHeight: 1800, frameCount }],
    })}\n`,
  );
  const jsonl =
    options.rawJsonl ?? `${options.records.map((record) => JSON.stringify(record)).join('\n')}\n`;
  await writeFile(join(options.directory, 'frames.jsonl'), jsonl);
  for (const record of options.records) {
    if (options.omitFiles?.includes(record.file)) continue;
    await writeFile(join(options.directory, record.file), 'placeholder');
  }
}

export async function* sourceFrames(
  records: CapturedFrameRecord[],
): AsyncGenerator<CapturedFrameRecord> {
  for (const record of records) yield record;
}
