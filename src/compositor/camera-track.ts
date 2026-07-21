import type { BBox, TimelineEvent } from '../timeline/types.js';
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
  events: readonly TimelineEvent[],
  durationMs: number,
  viewport: Size,
  policy: StudioCameraPolicy = STUDIO_CAMERA_POLICY,
): CameraTrack {
  if (!Number.isFinite(durationMs) || durationMs <= 0) {
    throw new Error('Camera track duration must be finite and positive');
  }
  const transitions: CameraTransitionSegment[] = [];
  const clicks = events.flatMap((event) => {
    let bbox: BBox | undefined;
    let focusMs: number | undefined;
    if (event.kind === 'click') {
      bbox = event.targetBboxAtCommit;
      focusMs = event.mouseDownMs;
    } else if (event.kind === 'moveTo') {
      bbox = event.targetBboxAtCommit;
      focusMs = event.endMs;
    } else if (event.kind === 'type') {
      bbox = event.targetBboxAtCommit;
      focusMs = event.focusMs;
    } else if (event.kind === 'scrollTo' && event.targetBboxAtCommit) {
      bbox = event.targetBboxAtCommit;
      focusMs = event.endMs;
    }
    return bbox && focusMs !== undefined
      ? [{ ...event, targetBboxAtCommit: bbox, mouseDownMs: focusMs }]
      : [];
  });
  let previousEndMs = 0;
  let previousState = establishCamera(viewport);
  for (const [index, click] of clicks.entries()) {
    if (index > 0 && click.startMs < (clicks[index - 1]?.startMs ?? 0)) {
      throw new Error('Camera focus events must be ordered');
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
      const previousClickId = transitions[index - 1]?.clickId;
      const hold: CameraHoldSegment = {
        id: index === 0 ? 'camera-establish' : `camera-hold-${String(index).padStart(3, '0')}`,
        phase: index === 0 ? 'establish' : 'hold',
        startMs: cursorMs,
        endMs: transition.startMs,
        state: heldState,
        ...(previousClickId ? { clickId: previousClickId } : {}),
      };
      segments.push(hold);
    }
    segments.push(transition);
    cursorMs = transition.endMs;
    heldState = transition.to;
  }
  if (cursorMs < durationMs) {
    const finalClickId = transitions.at(-1)?.clickId;
    segments.push({
      id: 'camera-hold-final',
      phase: 'hold',
      startMs: cursorMs,
      endMs: durationMs,
      state: heldState,
      ...(finalClickId ? { clickId: finalClickId } : {}),
    });
  }
  validateCameraSegments(segments, durationMs);
  return { durationMs, viewport, segments, transitions };
}

export function validateCameraSegments(
  segments: readonly CameraSegment[],
  durationMs: number,
): void {
  if (segments.length === 0) throw new Error('Camera track requires segments');
  let expectedStart = 0;
  let expectedState: CameraTransitionSegment['from'] | undefined;
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
      if (expectedState && !sameState(segment.from, expectedState)) {
        throw new Error('Camera transition is discontinuous with its preceding segment');
      }
      expectedState = segment.to;
    } else {
      if (expectedState && !sameState(segment.state, expectedState)) {
        throw new Error('Camera hold is discontinuous with its preceding segment');
      }
      expectedState = segment.state;
    }
    expectedStart = segment.endMs;
  }
  if (Math.abs(expectedStart - durationMs) > 1e-7) {
    throw new Error('Camera track must cover the composition duration');
  }
}

function sameState(
  left: CameraTransitionSegment['from'],
  right: CameraTransitionSegment['from'],
): boolean {
  return (
    Math.abs(left.zoom - right.zoom) <= 1e-10 &&
    Math.abs(left.centerCssX - right.centerCssX) <= 1e-10 &&
    Math.abs(left.centerCssY - right.centerCssY) <= 1e-10
  );
}
