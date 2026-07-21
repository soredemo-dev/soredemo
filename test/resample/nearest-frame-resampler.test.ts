import { describe, expect, it } from 'vitest';
import {
  resampleNearestFrames,
  selectNearestFrame,
} from '../../src/resample/nearest-frame-resampler.js';
import type { ResampledFrameRecord } from '../../src/resample/types.js';
import { sourceFrame, sourceFrames } from './capture-fixture.js';

async function resample(timestamps: number[], fps = 30) {
  const output: ResampledFrameRecord[] = [];
  const result = await resampleNearestFrames({
    sourceFrames: sourceFrames(
      timestamps.map((timestamp, index) => sourceFrame(index + 1, timestamp)),
    ),
    fps,
    onOutputFrame: (record) => {
      output.push(record);
    },
  });
  return { output, result };
}

describe('nearest source-frame selection', () => {
  const previous = sourceFrame(1, 0);
  const next = sourceFrame(2, 20);

  it('selects exact, closer previous, closer next, and previous on an exact tie', () => {
    expect(selectNearestFrame(previous, next, 0).index).toBe(1);
    expect(selectNearestFrame(previous, next, 7).index).toBe(1);
    expect(selectNearestFrame(previous, next, 13).index).toBe(2);
    expect(selectNearestFrame(previous, next, 10).index).toBe(1);
  });

  it('handles irregular input and is deterministic', async () => {
    const first = await resample([0, 9, 47, 52, 105], 20);
    const second = await resample([0, 9, 47, 52, 105], 20);
    expect(first.output).toEqual(second.output);
    expect(first.output.map((record) => record.sourceIndex)).toEqual([1, 4, 5]);
    expect(first.output[0]?.relation).toBe('exact');
  });

  it('skips high-frequency frames and repeats frames across low-frequency gaps', async () => {
    const highFrequency = await resample([0, 5, 10, 15, 20, 25, 30, 35, 40]);
    expect(highFrequency.result.statistics.sourceUsage.sourceFramesSkipped).toBeGreaterThan(0);
    const lowFrequency = await resample([0, 100, 200]);
    expect(
      lowFrequency.result.statistics.sourceUsage.outputFramesUsingRepeatedSource,
    ).toBeGreaterThan(0);
    expect(
      lowFrequency.result.statistics.sourceUsage.maxConsecutiveOutputFramesUsingOneSource,
    ).toBeGreaterThan(1);
    expect(lowFrequency.output[0]?.sourceIndex).toBe(1);
    expect(lowFrequency.output.at(-1)?.sourceIndex).toBe(3);
  });
});
