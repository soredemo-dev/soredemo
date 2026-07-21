import type { BBox, ClickTimelineEvent, Point, TimelineDocument } from './types.js';

export function isFinitePoint(point: Point): boolean {
  return Number.isFinite(point.x) && Number.isFinite(point.y);
}

export function isFinitePositiveBbox(bbox: BBox): boolean {
  return (
    isFinitePoint(bbox) &&
    Number.isFinite(bbox.width) &&
    Number.isFinite(bbox.height) &&
    bbox.width > 0 &&
    bbox.height > 0
  );
}

export function bboxContainsPoint(bbox: BBox, point: Point): boolean {
  return (
    point.x >= bbox.x &&
    point.x <= bbox.x + bbox.width &&
    point.y >= bbox.y &&
    point.y <= bbox.y + bbox.height
  );
}

export function bboxChangeCssPx(start: BBox, commit: BBox): number {
  return Math.max(
    Math.abs(start.x - commit.x),
    Math.abs(start.y - commit.y),
    Math.abs(start.width - commit.width),
    Math.abs(start.height - commit.height),
  );
}

export function validateClickTimelineEvent(event: ClickTimelineEvent): void {
  if (!event.id || event.kind !== 'click') throw new Error('Invalid click timeline identity');
  if (!isFinitePositiveBbox(event.targetBboxAtPathStart)) {
    throw new Error(`${event.id} has an invalid path-start bbox`);
  }
  if (!isFinitePositiveBbox(event.targetBboxAtCommit)) {
    throw new Error(`${event.id} has an invalid commit bbox`);
  }
  if (!bboxContainsPoint(event.targetBboxAtCommit, event.clickPoint)) {
    throw new Error(`${event.id} click point is outside its commit bbox`);
  }
  if (event.cursorPath.length < 2) throw new Error(`${event.id} cursor path is too short`);
  for (let index = 0; index < event.cursorPath.length; index += 1) {
    const point = event.cursorPath[index];
    if (!point || !isFinitePoint(point) || !Number.isFinite(point.timeMs)) {
      throw new Error(`${event.id} cursor path contains invalid data`);
    }
    const previous = event.cursorPath[index - 1];
    if (previous && point.timeMs <= previous.timeMs) {
      throw new Error(`${event.id} cursor path timestamps are not strictly increasing`);
    }
  }
  const finalPoint = event.cursorPath.at(-1);
  if (!finalPoint || finalPoint.x !== event.clickPoint.x || finalPoint.y !== event.clickPoint.y) {
    throw new Error(`${event.id} final cursor point does not equal its click point`);
  }
  if (
    !(
      event.startMs === event.cursorPath[0]?.timeMs &&
      event.startMs < event.mouseDownMs &&
      event.mouseDownMs <= event.mouseUpMs &&
      event.mouseUpMs <= event.endMs
    )
  ) {
    throw new Error(`${event.id} click timestamps are out of order`);
  }
}

export function validateTimelineDocument(
  document: TimelineDocument,
  captureDurationMs?: number,
): void {
  if (document.schemaVersion !== 1) throw new Error('Unsupported timeline schema version');
  const ids = new Set<string>();
  for (const event of document.events) {
    validateClickTimelineEvent(event);
    if (ids.has(event.id)) throw new Error(`Duplicate timeline event ID ${event.id}`);
    ids.add(event.id);
    if (captureDurationMs !== undefined && (event.startMs < 0 || event.endMs > captureDurationMs)) {
      throw new Error(`${event.id} falls outside the capture duration`);
    }
  }
}
