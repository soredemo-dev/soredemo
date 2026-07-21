import type { ClickTimelineEvent, TimedPoint } from './types.js';
import { validateClickTimelineEvent } from './validation.js';

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
  events: readonly ClickTimelineEvent[],
  viewport: { width: number; height: number },
): CursorTrack {
  if (events.length === 0) throw new Error('Cursor track requires at least one click event');
  if (!(viewport.width > 0 && viewport.height > 0)) throw new Error('Viewport must be positive');
  const movements: CursorMovement[] = [];
  let previousEvent: ClickTimelineEvent | undefined;
  let pointCount = 0;

  for (const event of events) {
    validateClickTimelineEvent(event);
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
