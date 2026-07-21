import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { ResamplePlanWriter } from '../../src/resample/resample-plan-writer.js';

describe('ResamplePlanWriter', () => {
  it('writes ordered newline-delimited mappings and a matching manifest', async () => {
    const outputDirectory = await mkdtemp(join(tmpdir(), 'soredemo-resample-plan-'));
    const writer = await ResamplePlanWriter.create(outputDirectory);
    await writer.writeFrame({
      outputIndex: 0,
      outputTimestampMs: 0,
      sourceIndex: 1,
      sourceFile: 'frames/000001.jpg',
      sourceTimestampMs: 0,
      signedSourceDeltaMs: 0,
      absoluteSourceDeltaMs: 0,
      relation: 'exact',
    });
    await writer.writeManifest({
      schemaVersion: 1,
      sourceCapturePath: '/capture',
      sourceCaptureSchemaVersion: 1,
      sourceFrameCount: 1,
      sourceDurationMs: 0,
      sourcePixelWidth: 2880,
      sourcePixelHeight: 1800,
      outputFps: 30,
      outputFrameCount: 1,
      outputDurationMs: 0,
      selectionPolicy: 'nearest-timestamp',
      tieBreakPolicy: 'earlier-frame',
      statistics: {
        selectedSourceErrorMs: { median: 0, p95: 0, max: 0 },
        signedSelection: { beforeCount: 0, exactCount: 1, afterCount: 0 },
        sourceUsage: {
          uniqueSourceFramesSelected: 1,
          sourceFramesSkipped: 0,
          outputFramesUsingRepeatedSource: 0,
          maxConsecutiveOutputFramesUsingOneSource: 1,
        },
        sourceCadenceMs: { min: 0, median: 0, p95: 0, max: 0 },
      },
    });
    await writer.close();
    const frames = await readFile(join(outputDirectory, 'frames.jsonl'), 'utf8');
    const manifest = JSON.parse(await readFile(join(outputDirectory, 'manifest.json'), 'utf8'));
    expect(frames.endsWith('\n')).toBe(true);
    expect(frames.trim().split('\n')).toHaveLength(1);
    expect(manifest.outputFrameCount).toBe(1);
  });
});
