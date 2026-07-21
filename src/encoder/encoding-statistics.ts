export function quantile(values: readonly number[], percentile: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((left, right) => left - right);
  const index = Math.max(0, Math.ceil(percentile * sorted.length) - 1);
  return sorted[index] ?? 0;
}

export function latencyStatistics(values: readonly number[]) {
  return {
    median: quantile(values, 0.5),
    p95: quantile(values, 0.95),
    max: values.length === 0 ? 0 : Math.max(...values),
  };
}
