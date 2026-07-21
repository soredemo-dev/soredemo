import type { TimedPoint, TimelineEvent } from './types.js';
import { validateTimelineEvent } from './validation.js';

const JOIN_TOLERANCE_CSS_PX = 1e-6;

export interface CursorMovement {
  clickId: string;
  points: readonly TimedPoint[];
}

export interface CursorTrack {
  movements: readonly CursorMovement[];
  pointCount: number;
  firstPointMs: number;
  lastPointMs: number;
}

export function buildCursorTrack(
  allEvents: readonly TimelineEvent[],
  viewport: { width: number; height: number },
): CursorTrack {
  const events = allEvents.filter(
    (event) => event.kind === 'click' || event.kind === 'moveTo' || event.kind === 'type',
  );
  if (!(viewport.width > 0 && viewport.height > 0)) throw new Error('Viewport must be positive');
  if (events.length === 0) {
    return { movements: [], pointCount: 0, firstPointMs: 0, lastPointMs: 0 };
  }
  const movements: CursorMovement[] = [];
  let previousEvent: (typeof events)[number] | undefined;
  let pointCount = 0;

  for (const event of events) {
    validateTimelineEvent(event);
    const first = event.cursorPath[0];
    const final = event.cursorPath.at(-1);
    if (!first || !final) throw new Error(`${event.id} has no cursor path`);
    if (previousEvent) {
      const previousFinal = previousEvent.cursorPath.at(-1);
      if (!previousFinal || first.timeMs <= previousFinal.timeMs) {
        throw new Error(`${event.id} cursor path overlaps the previous movement`);
      }
      if (
        Math.abs(first.x - previousFinal.x) > JOIN_TOLERANCE_CSS_PX ||
        Math.abs(first.y - previousFinal.y) > JOIN_TOLERANCE_CSS_PX
      ) {
        throw new Error(`${event.id} cursor path jumps from the previous held position`);
      }
    }
    for (const point of event.cursorPath) {
      if (point.x < 0 || point.x > viewport.width || point.y < 0 || point.y > viewport.height) {
        throw new Error(`${event.id} cursor path leaves the CSS viewport`);
      }
    }
    movements.push({ clickId: event.id, points: event.cursorPath });
    pointCount += event.cursorPath.length;
    previousEvent = event;
  }

  const firstPointMs = movements[0]?.points[0]?.timeMs;
  const lastPointMs = movements.at(-1)?.points.at(-1)?.timeMs;
  if (firstPointMs === undefined || lastPointMs === undefined) {
    throw new Error('Cursor track endpoints are missing');
  }
  return { movements, pointCount, firstPointMs, lastPointMs };
}
