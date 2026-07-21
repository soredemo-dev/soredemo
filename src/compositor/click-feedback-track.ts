import BezierEasing from 'bezier-easing';
import type { ClickTimelineEvent, Point } from '../timeline/types.js';

export const CLICK_RIPPLE_STYLE = {
  durationMs: 260,
  startRadius: 3,
  endRadius: 20,
  strokeWidth: 2,
  backingStrokeWidth: 4,
  backingOpacityFactor: 0.35,
  startOpacity: 0.55,
  endOpacity: 0,
} as const;

export interface ClickRippleFrameState {
  clickId: string;
  clickPoint: Point;
  mouseDownMs: number;
  progress: number;
  easedProgress: number;
  radius: number;
  opacity: number;
}

export interface ClickFeedbackTrack {
  clicks: readonly ClickTimelineEvent[];
}

const rippleEasing = BezierEasing(0.22, 1, 0.36, 1);

export function buildClickFeedbackTrack(clicks: readonly ClickTimelineEvent[]): ClickFeedbackTrack {
  let previous = Number.NEGATIVE_INFINITY;
  const ids = new Set<string>();
  for (const click of clicks) {
    if (!Number.isFinite(click.mouseDownMs) || click.mouseDownMs < previous) {
      throw new Error('Click feedback events must have ordered finite mouse-down times');
    }
    if (ids.has(click.id)) throw new Error('Click feedback event IDs must be unique');
    ids.add(click.id);
    previous = click.mouseDownMs;
  }
  return { clicks: [...clicks] };
}

export class SequentialClickFeedbackEvaluator {
  private nextIndex = 0;
  private active: ClickTimelineEvent[] = [];
  private previousTimeMs = Number.NEGATIVE_INFINITY;

  constructor(private readonly track: ClickFeedbackTrack) {}

  evaluate(outputTimestampMs: number): ClickRippleFrameState[] {
    if (!Number.isFinite(outputTimestampMs) || outputTimestampMs < 0) {
      throw new Error('Click feedback time must be finite and non-negative');
    }
    if (outputTimestampMs < this.previousTimeMs) {
      throw new Error('Sequential click feedback time moved backward');
    }
    this.previousTimeMs = outputTimestampMs;
    while (
      this.nextIndex < this.track.clicks.length &&
      (this.track.clicks[this.nextIndex]?.mouseDownMs ?? Number.POSITIVE_INFINITY) <=
        outputTimestampMs
    ) {
      const click = this.track.clicks[this.nextIndex];
      if (!click) throw new Error('Click feedback track index is invalid');
      this.active.push(click);
      this.nextIndex += 1;
    }
    this.active = this.active.filter(
      (click) => outputTimestampMs < click.mouseDownMs + CLICK_RIPPLE_STYLE.durationMs,
    );
    return this.active.map((click) => rippleState(click, outputTimestampMs));
  }
}

function rippleState(click: ClickTimelineEvent, outputTimestampMs: number): ClickRippleFrameState {
  const progress = Math.min(
    1,
    Math.max(0, (outputTimestampMs - click.mouseDownMs) / CLICK_RIPPLE_STYLE.durationMs),
  );
  const easedProgress = rippleEasing(progress);
  return {
    clickId: click.id,
    clickPoint: click.clickPoint,
    mouseDownMs: click.mouseDownMs,
    progress,
    easedProgress,
    radius:
      CLICK_RIPPLE_STYLE.startRadius +
      (CLICK_RIPPLE_STYLE.endRadius - CLICK_RIPPLE_STYLE.startRadius) * easedProgress,
    opacity:
      CLICK_RIPPLE_STYLE.startOpacity +
      (CLICK_RIPPLE_STYLE.endOpacity - CLICK_RIPPLE_STYLE.startOpacity) * easedProgress,
  };
}
