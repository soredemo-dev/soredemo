import { describe, expect, it } from 'vitest';
import { exactDistribution, StreamingDistribution } from '../../src/resample/statistics.js';

describe('resample statistics', () => {
  it('calculates exact diagnostics for small event sets', () => {
    expect(exactDistribution([1, 2, 3, 4, 10])).toEqual({
      median: 3,
      p95: 8.799999999999999,
      max: 10,
    });
  });

  it('keeps bounded streaming quantile state with stable estimates', () => {
    const distribution = new StreamingDistribution();
    for (let value = 1; value <= 10_000; value += 1) distribution.add(value);
    const summary = distribution.summary();
    expect(summary.min).toBe(1);
    expect(summary.max).toBe(10_000);
    expect(summary.median).toBeCloseTo(5_000, -1);
    expect(summary.p95).toBeCloseTo(9_500, -1);
  });
});
