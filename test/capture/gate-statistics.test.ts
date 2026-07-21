import { describe, expect, it } from 'vitest';
import { summarizeDistribution } from '../../src/capture/gate-statistics.js';

describe('gate statistics', () => {
  it('calculates interpolated aggregate percentiles', () => {
    expect(summarizeDistribution([1, 2, 3, 4, 10])).toEqual({
      min: 1,
      median: 3,
      p95: 8.799999999999999,
      max: 10,
    });
  });
});
