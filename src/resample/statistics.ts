import type { DistributionStatistics } from './types.js';

class P2Quantile {
  private readonly initial: number[] = [];
  private heights: number[] = [];
  private positions: number[] = [];
  private desired: number[] = [];
  private readonly increments: number[];

  constructor(private readonly probability: number) {
    if (!(probability > 0 && probability < 1)) throw new Error('Quantile must be between 0 and 1');
    this.increments = [0, probability / 2, probability, (1 + probability) / 2, 1];
  }

  add(value: number): void {
    if (!Number.isFinite(value)) throw new Error('Statistic value must be finite');
    if (this.initial.length < 5) {
      this.initial.push(value);
      if (this.initial.length === 5) this.initialize();
      return;
    }

    let bucket = 0;
    if (value < (this.heights[0] ?? value)) {
      this.heights[0] = value;
      bucket = 0;
    } else if (value < (this.heights[1] ?? value)) bucket = 0;
    else if (value < (this.heights[2] ?? value)) bucket = 1;
    else if (value < (this.heights[3] ?? value)) bucket = 2;
    else if (value <= (this.heights[4] ?? value)) bucket = 3;
    else {
      this.heights[4] = value;
      bucket = 3;
    }
    for (let index = bucket + 1; index < 5; index += 1) {
      this.positions[index] = (this.positions[index] ?? 0) + 1;
    }
    for (let index = 0; index < 5; index += 1) {
      this.desired[index] = (this.desired[index] ?? 0) + (this.increments[index] ?? 0);
    }
    for (let index = 1; index <= 3; index += 1) this.adjust(index);
  }

  value(): number {
    if (this.initial.length === 0) throw new Error('Quantile has no values');
    if (this.initial.length < 5) return exactQuantile(this.initial, this.probability);
    return this.heights[2] ?? 0;
  }

  private initialize(): void {
    this.heights = [...this.initial].sort((left, right) => left - right);
    this.positions = [1, 2, 3, 4, 5];
    this.desired = [
      1,
      1 + 2 * this.probability,
      1 + 4 * this.probability,
      3 + 2 * this.probability,
      5,
    ];
  }

  private adjust(index: number): void {
    const desiredDelta = (this.desired[index] ?? 0) - (this.positions[index] ?? 0);
    const nextGap = (this.positions[index + 1] ?? 0) - (this.positions[index] ?? 0);
    const previousGap = (this.positions[index - 1] ?? 0) - (this.positions[index] ?? 0);
    if (!((desiredDelta >= 1 && nextGap > 1) || (desiredDelta <= -1 && previousGap < -1))) return;
    const direction = Math.sign(desiredDelta);
    const currentPosition = this.positions[index] ?? 0;
    const previousPosition = this.positions[index - 1] ?? 0;
    const nextPosition = this.positions[index + 1] ?? 0;
    const currentHeight = this.heights[index] ?? 0;
    const previousHeight = this.heights[index - 1] ?? 0;
    const nextHeight = this.heights[index + 1] ?? 0;
    const parabolic =
      currentHeight +
      (direction / (nextPosition - previousPosition)) *
        (((currentPosition - previousPosition + direction) * (nextHeight - currentHeight)) /
          (nextPosition - currentPosition) +
          ((nextPosition - currentPosition - direction) * (currentHeight - previousHeight)) /
            (currentPosition - previousPosition));
    if (previousHeight < parabolic && parabolic < nextHeight) {
      this.heights[index] = parabolic;
    } else {
      const adjacentIndex = index + direction;
      this.heights[index] =
        currentHeight +
        (direction * ((this.heights[adjacentIndex] ?? 0) - currentHeight)) /
          ((this.positions[adjacentIndex] ?? 0) - currentPosition);
    }
    this.positions[index] = currentPosition + direction;
  }
}

export class StreamingDistribution {
  private count = 0;
  private maximum = Number.NEGATIVE_INFINITY;
  private minimum = Number.POSITIVE_INFINITY;
  private readonly median = new P2Quantile(0.5);
  private readonly p95 = new P2Quantile(0.95);

  add(value: number): void {
    if (!Number.isFinite(value)) throw new Error('Statistic value must be finite');
    this.count += 1;
    this.minimum = Math.min(this.minimum, value);
    this.maximum = Math.max(this.maximum, value);
    this.median.add(value);
    this.p95.add(value);
  }

  summary(): DistributionStatistics & { min: number } {
    if (this.count === 0) throw new Error('Cannot summarize an empty distribution');
    return {
      min: this.minimum,
      median: this.median.value(),
      p95: this.p95.value(),
      max: this.maximum,
    };
  }
}

export function exactDistribution(values: number[]): DistributionStatistics {
  if (values.length === 0 || values.some((value) => !Number.isFinite(value))) {
    throw new Error('Distribution requires finite values');
  }
  return {
    median: exactQuantile(values, 0.5),
    p95: exactQuantile(values, 0.95),
    max: Math.max(...values),
  };
}

function exactQuantile(values: number[], probability: number): number {
  const sorted = [...values].sort((left, right) => left - right);
  const position = (sorted.length - 1) * probability;
  const lower = Math.floor(position);
  const upper = Math.ceil(position);
  const lowerValue = sorted[lower] ?? 0;
  const upperValue = sorted[upper] ?? lowerValue;
  return lowerValue + (upperValue - lowerValue) * (position - lower);
}
