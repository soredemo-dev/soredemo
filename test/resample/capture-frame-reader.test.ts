import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { CapturedFrameRecord } from '../../src/capture/types.js';
import { openCaptureFrameReader } from '../../src/resample/capture-frame-reader.js';
import { sourceFrame, writeCaptureFixture } from './capture-fixture.js';

async function directory(): Promise<string> {
  return mkdtemp(join(tmpdir(), 'soredemo-resample-reader-'));
}

async function consume(captureDirectory: string): Promise<CapturedFrameRecord[]> {
  const reader = await openCaptureFrameReader(captureDirectory);
  const records: CapturedFrameRecord[] = [];
  for await (const record of reader.frames()) records.push(record);
  return records;
}

describe('streaming capture frame reader', () => {
  it('reads valid records incrementally without opening JPEG content', async () => {
    const captureDirectory = await directory();
    const records = [sourceFrame(1, 0), sourceFrame(2, 10)];
    await writeCaptureFixture({ directory: captureDirectory, records });
    expect(await consume(captureDirectory)).toEqual(records);
  });

  it('rejects duplicate and backward timestamps without sorting', async () => {
    const duplicateDirectory = await directory();
    await writeCaptureFixture({
      directory: duplicateDirectory,
      records: [sourceFrame(1, 0), sourceFrame(2, 0)],
    });
    await expect(consume(duplicateDirectory)).rejects.toThrow('strictly increasing');

    const backwardDirectory = await directory();
    await writeCaptureFixture({
      directory: backwardDirectory,
      records: [sourceFrame(1, 0), sourceFrame(2, 20), sourceFrame(3, 10)],
    });
    await expect(consume(backwardDirectory)).rejects.toThrow('strictly increasing');
  });

  it('rejects missing indices and unexpected filenames', async () => {
    const indexDirectory = await directory();
    await writeCaptureFixture({
      directory: indexDirectory,
      records: [sourceFrame(1, 0), sourceFrame(3, 10)],
    });
    await expect(consume(indexDirectory)).rejects.toThrow('Expected source frame index 2');

    const filenameDirectory = await directory();
    await writeCaptureFixture({
      directory: filenameDirectory,
      records: [sourceFrame(1, 0, { file: 'frames/other.jpg' })],
    });
    await expect(consume(filenameDirectory)).rejects.toThrow('unexpected or duplicate filename');
  });

  it('rejects malformed JSONL and non-finite metadata representations', async () => {
    const malformedDirectory = await directory();
    await writeCaptureFixture({
      directory: malformedDirectory,
      records: [sourceFrame(1, 0)],
      rawJsonl: '{not-json}\n',
    });
    await expect(consume(malformedDirectory)).rejects.toThrow('Malformed');

    const invalidNumberDirectory = await directory();
    await writeCaptureFixture({
      directory: invalidNumberDirectory,
      records: [sourceFrame(1, 0)],
      rawJsonl: `${JSON.stringify({ ...sourceFrame(1, 0), timestampMs: 'NaN' })}\n`,
    });
    await expect(consume(invalidNumberDirectory)).rejects.toThrow('finite number');
  });

  it('rejects manifest count, dimensions, and missing JPEG mismatches', async () => {
    const countDirectory = await directory();
    await writeCaptureFixture({
      directory: countDirectory,
      records: [sourceFrame(1, 0)],
      manifestFrameCount: 2,
    });
    await expect(consume(countDirectory)).rejects.toThrow('does not match');

    const dimensionDirectory = await directory();
    await writeCaptureFixture({
      directory: dimensionDirectory,
      records: [sourceFrame(1, 0), sourceFrame(2, 10, { pixelWidth: 1440 })],
    });
    await expect(consume(dimensionDirectory)).rejects.toThrow('inconsistent dimensions');

    const missingFileDirectory = await directory();
    const missing = sourceFrame(1, 0);
    await writeCaptureFixture({
      directory: missingFileDirectory,
      records: [missing],
      omitFiles: [missing.file],
    });
    await expect(consume(missingFileDirectory)).rejects.toThrow('missing or unreadable');
  });

  it('requires the first timestamp to be zero within tolerance', async () => {
    const captureDirectory = await directory();
    await writeCaptureFixture({
      directory: captureDirectory,
      records: [sourceFrame(1, 0.01)],
    });
    await expect(consume(captureDirectory)).rejects.toThrow('must equal zero');
  });
});
