import { mkdtemp, readdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { CaptureBundleWriter } from '../../src/capture/capture-bundle-writer.js';
import type { QueuedCaptureFrame } from '../../src/capture/types.js';
import { syntheticJpeg } from './jpeg-fixture.js';

function frame(index: number): QueuedCaptureFrame {
  return {
    index,
    data: syntheticJpeg(2880, 1800),
    metadata: {
      offsetTop: 0,
      pageScaleFactor: 1,
      deviceWidth: 1440,
      deviceHeight: 900,
      scrollOffsetX: 0,
      scrollOffsetY: 0,
      timestamp: 1_750_000_000 + index / 30,
    },
    timestampMs: (index - 1) * (1000 / 30),
    receivedAtMs: (index - 1) * (1000 / 30) + 2,
  };
}

describe('CaptureBundleWriter', () => {
  it('writes ordered JPEG files and newline-delimited frame records', async () => {
    const outputDirectory = await mkdtemp(join(tmpdir(), 'soredemo-capture-writer-'));
    const writer = await CaptureBundleWriter.create({ outputDirectory, queueLimit: 4 });
    for (let index = 1; index <= 3; index += 1) {
      writer.markReceived();
      writer.enqueue(frame(index));
      writer.markAcknowledged();
    }
    await writer.close();

    const files = await readdir(join(outputDirectory, 'frames'));
    const jsonl = await readFile(join(outputDirectory, 'frames.jsonl'), 'utf8');
    const records = jsonl
      .trim()
      .split('\n')
      .map((line) => JSON.parse(line));
    expect(files).toEqual(['000001.jpg', '000002.jpg', '000003.jpg']);
    expect(jsonl.endsWith('\n')).toBe(true);
    expect(records.map((record) => record.index)).toEqual([1, 2, 3]);
    expect(records[0]).toMatchObject({
      file: 'frames/000001.jpg',
      pixelWidth: 2880,
      pixelHeight: 1800,
    });
    expect(writer.diagnostics).toMatchObject({
      received: 3,
      acknowledged: 3,
      written: 3,
      overflowCount: 0,
      writeFailures: 0,
    });
  });

  it('fails loudly instead of exceeding the bounded queue', async () => {
    const outputDirectory = await mkdtemp(join(tmpdir(), 'soredemo-capture-overflow-'));
    const writer = await CaptureBundleWriter.create({ outputDirectory, queueLimit: 1 });
    writer.enqueue(frame(1));

    expect(() => writer.enqueue(frame(2))).toThrow('Capture queue exceeded its limit of 1');
    expect(writer.diagnostics.overflowCount).toBe(1);
    await writer.close();
  });
});
