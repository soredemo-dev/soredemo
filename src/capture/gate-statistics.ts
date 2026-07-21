export interface Distribution {
  min: number;
  median: number;
  p95: number;
  max: number;
}

export function summarizeDistribution(values: number[]): Distribution {
  if (values.length === 0) throw new Error('Cannot summarize an empty distribution');
  if (values.some((value) => !Number.isFinite(value))) {
    throw new Error('Distribution contains a non-finite value');
  }
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
