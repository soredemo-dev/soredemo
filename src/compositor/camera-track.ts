import type { ClickTimelineEvent } from '../timeline/types.js';
import {
  establishCamera,
  focusCamera,
  STUDIO_CAMERA_POLICY,
  type StudioCameraPolicy,
  transitionDurationMs,
} from './camera-policy.js';
import type {
  CameraHoldSegment,
  CameraSegment,
  CameraTrack,
  CameraTransitionSegment,
  Size,
} from './camera-types.js';

export function buildCameraTrack(
  clicks: readonly ClickTimelineEvent[],
  durationMs: number,
  viewport: Size,
  policy: StudioCameraPolicy = STUDIO_CAMERA_POLICY,
): CameraTrack {
  if (!Number.isFinite(durationMs) || durationMs <= 0) {
    throw new Error('Camera track duration must be finite and positive');
  }
  const transitions: CameraTransitionSegment[] = [];
  let previousEndMs = 0;
  let previousState = establishCamera(viewport);
  for (const [index, click] of clicks.entries()) {
    if (index > 0 && click.startMs < (clicks[index - 1]?.startMs ?? 0)) {
      throw new Error('Camera click events must be ordered');
    }
    const to = focusCamera(click.targetBboxAtCommit, viewport, policy);
    const proposedDuration = transitionDurationMs(previousState, to, viewport, policy);
    const earliest = index === 0 ? policy.establishDurationMs : previousEndMs;
    const desiredStart = Math.max(earliest, click.startMs - policy.leadMs);
    const latestEnd = click.mouseDownMs - policy.settleBeforeClickMs;
    let startMs = desiredStart;
    let endMs = Math.min(latestEnd, startMs + proposedDuration);
    let compressed = endMs - startMs < policy.transitionMinMs;
    if (compressed && latestEnd - earliest >= policy.transitionMinMs) {
      startMs = Math.max(earliest, latestEnd - policy.transitionMinMs);
      endMs = latestEnd;
      compressed = false;
    }
    if (endMs <= startMs) {
      throw new Error(`${click.id} has no positive camera transition window`);
    }
    const transition: CameraTransitionSegment = {
      id: `camera-transition-${String(index + 1).padStart(3, '0')}`,
      phase: 'transition',
      clickId: click.id,
      startMs,
      endMs,
      from: previousState,
      to,
      compressed,
    };
    transitions.push(transition);
    previousEndMs = endMs;
    previousState = to;
  }

  const segments: CameraSegment[] = [];
  let cursorMs = 0;
  let heldState = establishCamera(viewport);
  for (const [index, transition] of transitions.entries()) {
    if (transition.startMs > cursorMs) {
      const hold: CameraHoldSegment = {
        id: index === 0 ? 'camera-establish' : `camera-hold-${String(index).padStart(3, '0')}`,
        phase: index === 0 ? 'establish' : 'hold',
        startMs: cursorMs,
        endMs: transition.startMs,
        state: heldState,
        ...(index === 0 ? {} : { clickId: transitions[index - 1]?.clickId }),
      };
      segments.push(hold);
    }
    segments.push(transition);
    cursorMs = transition.endMs;
    heldState = transition.to;
  }
  if (cursorMs < durationMs) {
    segments.push({
      id: 'camera-hold-final',
      phase: 'hold',
      startMs: cursorMs,
      endMs: durationMs,
      state: heldState,
      ...(transitions.at(-1) ? { clickId: transitions.at(-1)?.clickId } : {}),
    });
  }
  validateCameraSegments(segments, durationMs);
  return { durationMs, viewport, segments, transitions };
}

export function validateCameraSegments(segments: readonly CameraSegment[], durationMs: number): void {
  if (segments.length === 0) throw new Error('Camera track requires segments');
  let expectedStart = 0;
  for (const segment of segments) {
    if (Math.abs(segment.startMs - expectedStart) > 1e-7 || segment.endMs <= segment.startMs) {
      throw new Error('Camera segments must be contiguous and positive');
    }
    if (segment.phase === 'transition') {
      const values = [segment.from, segment.to].flatMap((state) => [
        state.zoom,
        state.centerCssX,
        state.centerCssY,
      ]);
      if (!values.every(Number.isFinite)) throw new Error('Camera transition state must be finite');
    }
    expectedStart = segment.endMs;
  }
  if (Math.abs(expectedStart - durationMs) > 1e-7) {
    throw new Error('Camera track must cover the composition duration');
  }
}
