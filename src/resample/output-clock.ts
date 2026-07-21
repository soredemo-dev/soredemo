export const OUTPUT_FPS = 30 as const;

export function outputTimestampForIndex(outputIndex: number, fps: number = OUTPUT_FPS): number {
  if (!Number.isInteger(outputIndex) || outputIndex < 0) {
    throw new Error('Output frame index must be a non-negative integer');
  }
  if (!Number.isFinite(fps) || fps <= 0) throw new Error('Output fps must be positive');
  return (outputIndex * 1000) / fps;
}

export function outputFrameCount(sourceDurationMs: number, fps: number = OUTPUT_FPS): number {
  if (!Number.isFinite(sourceDurationMs) || sourceDurationMs < 0) {
    throw new Error('Source duration must be finite and non-negative');
  }
  if (!Number.isFinite(fps) || fps <= 0) throw new Error('Output fps must be positive');
  return Math.floor((sourceDurationMs * fps) / 1000) + 1;
}

export function* outputClock(
  sourceDurationMs: number,
  fps: number = OUTPUT_FPS,
): Generator<{ outputIndex: number; outputTimestampMs: number }> {
  const count = outputFrameCount(sourceDurationMs, fps);
  for (let outputIndex = 0; outputIndex < count; outputIndex += 1) {
    const outputTimestampMs = outputTimestampForIndex(outputIndex, fps);
    if (outputTimestampMs > sourceDurationMs) {
      throw new Error('Output clock generated a timestamp beyond the source duration');
    }
    yield { outputIndex, outputTimestampMs };
  }
}
