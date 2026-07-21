import BezierEasing from 'bezier-easing';
import { visibleCssRect } from './camera-projection.js';
import type { CameraFrameState, CameraTrack } from './camera-types.js';

const cameraEasing = BezierEasing(0.22, 1, 0.36, 1);

export class SequentialCameraEvaluator {
  private segmentIndex = 0;
  private previousTimeMs = Number.NEGATIVE_INFINITY;

  constructor(private readonly track: CameraTrack) {}

  evaluate(outputTimestampMs: number): CameraFrameState {
    if (!Number.isFinite(outputTimestampMs) || outputTimestampMs < 0) {
      throw new Error('Camera evaluation time must be finite and non-negative');
    }
    if (outputTimestampMs < this.previousTimeMs) {
      throw new Error('Sequential camera evaluation time moved backward');
    }
    if (outputTimestampMs > this.track.durationMs + 1e-7) {
      throw new Error('Camera evaluation time exceeds track duration');
    }
    this.previousTimeMs = outputTimestampMs;
    while (
      this.segmentIndex + 1 < this.track.segments.length &&
      outputTimestampMs >= (this.track.segments[this.segmentIndex]?.endMs ?? Number.POSITIVE_INFINITY)
    ) {
      this.segmentIndex += 1;
    }
    const segment = this.track.segments[this.segmentIndex];
    if (!segment) throw new Error('Camera evaluator has no active segment');
    if (segment.phase !== 'transition') {
      return {
        ...segment.state,
        outputTimestampMs,
        segmentId: segment.id,
        phase: segment.phase,
        visibleCssRect: visibleCssRect(segment.state, this.track.viewport),
      };
    }
    const linearProgress = Math.min(
      1,
      Math.max(0, (outputTimestampMs - segment.startMs) / (segment.endMs - segment.startMs)),
    );
    const easedProgress = cameraEasing(linearProgress);
    const state = {
      zoom: interpolate(segment.from.zoom, segment.to.zoom, easedProgress),
      centerCssX: interpolate(segment.from.centerCssX, segment.to.centerCssX, easedProgress),
      centerCssY: interpolate(segment.from.centerCssY, segment.to.centerCssY, easedProgress),
    };
    return {
      ...state,
      outputTimestampMs,
      segmentId: segment.id,
      phase: 'transition',
      linearProgress,
      easedProgress,
      visibleCssRect: visibleCssRect(state, this.track.viewport),
    };
  }
}

function interpolate(from: number, to: number, progress: number): number {
  return from + (to - from) * progress;
}
