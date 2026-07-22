import type { CameraTrack } from '../../src/compositor/camera-types.js';
import { CLICK_RIPPLE_STYLE } from '../../src/compositor/click-feedback-track.js';
import type { ResampledFrameRecord } from '../../src/resample/types.js';
import type {
  ClickTimelineEvent,
  MoveToTimelineEvent,
  TimelineDocument,
  TypeTimelineEvent,
} from '../../src/timeline/types.js';
import { GoldenError } from './types.js';

export interface SemanticFrameSelection {
  purpose: string;
  record: ResampledFrameRecord;
}

export function selectCanonicalFrames(
  records: readonly ResampledFrameRecord[],
  timeline: TimelineDocument,
  cameraTrack: CameraTrack,
): SemanticFrameSelection[] {
  const moveTo = timeline.events.find(
    (event): event is MoveToTimelineEvent => event.kind === 'moveTo',
  );
  const clicks = timeline.events.filter(
    (event): event is ClickTimelineEvent => event.kind === 'click',
  );
  const type = timeline.events.find((event): event is TypeTimelineEvent => event.kind === 'type');
  const transition = cameraTrack.transitions[0];
  const firstClick = clicks[0];
  const secondClick = clicks[1];
  const last = records.at(-1);
  if (!moveTo || !firstClick || !secondClick || !type || !transition || !last) {
    throw new GoldenError(
      'GOLDEN_FRAME_MISSING',
      'Canonical inputs do not exercise the required visual states',
    );
  }
  const moveFirst = moveTo.cursorPath[0];
  const moveFinal = moveTo.cursorPath.at(-1);
  if (!moveFirst || !moveFinal) {
    throw new GoldenError('GOLDEN_FRAME_MISSING', 'Canonical moveTo path is incomplete');
  }
  const requested: Array<[string, number, 'nearest' | 'at-or-after']> = [
    ['establish', 0, 'nearest'],
    ['camera-transition-start', transition.startMs, 'nearest'],
    ['move-to-interpolation', (moveFirst.timeMs + moveFinal.timeMs) / 2, 'nearest'],
    ['camera-transition-midpoint', (transition.startMs + transition.endMs) / 2, 'nearest'],
    ['camera-transition-completion', transition.endMs, 'at-or-after'],
    ['move-to-landing', moveFinal.timeMs, 'at-or-after'],
    ['click-ripple-start', firstClick.mouseDownMs, 'at-or-after'],
    [
      'click-ripple-midpoint',
      firstClick.mouseDownMs + CLICK_RIPPLE_STYLE.durationMs / 2,
      'at-or-after',
    ],
    [
      'click-ripple-completion',
      firstClick.mouseDownMs + CLICK_RIPPLE_STYLE.durationMs,
      'at-or-after',
    ],
    ['type-focus', type.focusMs, 'at-or-after'],
    ['second-click', secondClick.mouseDownMs, 'at-or-after'],
    ['rounded-corner', secondClick.endMs, 'at-or-after'],
    ['final', last.outputTimestampMs, 'nearest'],
  ];
  const selected = requested.map(([purpose, timestamp, policy]) => ({
    purpose,
    record: policy === 'nearest' ? nearest(records, timestamp) : firstAtOrAfter(records, timestamp),
  }));
  const purposes = new Set<string>();
  for (const selection of selected) {
    if (purposes.has(selection.purpose)) {
      throw new GoldenError('GOLDEN_MANIFEST_INVALID', `Duplicate purpose ${selection.purpose}`);
    }
    purposes.add(selection.purpose);
  }
  return selected;
}

function firstAtOrAfter(
  records: readonly ResampledFrameRecord[],
  timestampMs: number,
): ResampledFrameRecord {
  const record = records.find((candidate) => candidate.outputTimestampMs >= timestampMs - 1e-9);
  if (!record) {
    throw new GoldenError(
      'GOLDEN_FRAME_MISSING',
      `No canonical frame occurs at or after ${timestampMs}ms`,
    );
  }
  return record;
}

function nearest(
  records: readonly ResampledFrameRecord[],
  timestampMs: number,
): ResampledFrameRecord {
  const record = records.reduce<ResampledFrameRecord | undefined>((best, candidate) => {
    if (!best) return candidate;
    const candidateDistance = Math.abs(candidate.outputTimestampMs - timestampMs);
    const bestDistance = Math.abs(best.outputTimestampMs - timestampMs);
    return candidateDistance < bestDistance ? candidate : best;
  }, undefined);
  if (!record) throw new GoldenError('GOLDEN_FRAME_MISSING', 'Canonical frame plan is empty');
  return record;
}
