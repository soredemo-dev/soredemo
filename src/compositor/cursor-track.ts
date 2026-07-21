import type { CursorTrack } from '../timeline/cursor-track-validation.js';

export type CursorInterpolation = 'hidden' | 'exact' | 'linear' | 'held';

export interface CursorFrameState {
  visible: boolean;
  cssX?: number;
  cssY?: number;
  screenX?: number;
  screenY?: number;
  activeClickId?: string;
  interpolation: CursorInterpolation;
}

export class SequentialCursorEvaluator {
  private movementIndex = 0;
  private pointIndex = 0;
  private previousTimeMs = Number.NEGATIVE_INFINITY;

  constructor(private readonly track: CursorTrack) {}

  evaluate(outputTimestampMs: number): CursorFrameState {
    if (!Number.isFinite(outputTimestampMs))
      throw new Error('Cursor evaluation time must be finite');
    if (outputTimestampMs < this.previousTimeMs) {
      throw new Error('Sequential cursor evaluation time moved backward');
    }
    this.previousTimeMs = outputTimestampMs;
    const firstMovement = this.track.movements[0];
    const firstPoint = firstMovement?.points[0];
    if (!firstMovement || !firstPoint || outputTimestampMs < firstPoint.timeMs) {
      return { visible: false, interpolation: 'hidden' };
    }

    while (this.movementIndex + 1 < this.track.movements.length) {
      const nextFirst = this.track.movements[this.movementIndex + 1]?.points[0];
      if (!nextFirst || outputTimestampMs < nextFirst.timeMs) break;
      this.movementIndex += 1;
      this.pointIndex = 0;
    }
    const movement = this.track.movements[this.movementIndex];
    if (!movement) throw new Error('Cursor movement state is invalid');
    const points = movement.points;
    const final = points.at(-1);
    if (!final) throw new Error('Cursor movement is empty');
    if (outputTimestampMs > final.timeMs) {
      return {
        visible: true,
        cssX: final.x,
        cssY: final.y,
        activeClickId: movement.clickId,
        interpolation: 'held',
      };
    }

    while (
      this.pointIndex + 1 < points.length &&
      outputTimestampMs >= (points[this.pointIndex + 1]?.timeMs ?? Number.POSITIVE_INFINITY)
    ) {
      this.pointIndex += 1;
    }
    const left = points[this.pointIndex];
    if (!left) throw new Error('Cursor point state is invalid');
    if (outputTimestampMs === left.timeMs || this.pointIndex === points.length - 1) {
      return {
        visible: true,
        cssX: left.x,
        cssY: left.y,
        activeClickId: movement.clickId,
        interpolation: 'exact',
      };
    }
    const right = points[this.pointIndex + 1];
    if (!right) throw new Error('Cursor interpolation endpoint is missing');
    const progress = (outputTimestampMs - left.timeMs) / (right.timeMs - left.timeMs);
    return {
      visible: true,
      cssX: left.x + (right.x - left.x) * progress,
      cssY: left.y + (right.y - left.y) * progress,
      activeClickId: movement.clickId,
      interpolation: 'linear',
    };
  }
}
