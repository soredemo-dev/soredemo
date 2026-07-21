import type {
  BBox,
  ClickTimelineEvent,
  MoveToTimelineEvent,
  Point,
  TimedPoint,
  TimelineDocument,
  TimelineEvent,
  TypeTimelineEvent,
} from './types.js';

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

function validatePath(id: string, path: readonly TimedPoint[], destination: Point): void {
  if (path.length < 2) throw new Error(`${id} cursor path is too short`);
  for (let index = 0; index < path.length; index += 1) {
    const point = path[index];
    if (!point || !isFinitePoint(point) || !Number.isFinite(point.timeMs))
      throw new Error(`${id} cursor path contains invalid data`);
    const previous = path[index - 1];
    if (previous && point.timeMs <= previous.timeMs)
      throw new Error(`${id} cursor path timestamps are not strictly increasing`);
  }
  const final = path.at(-1);
  if (!final || final.x !== destination.x || final.y !== destination.y)
    throw new Error(`${id} final cursor point does not equal its destination`);
}

export function validateClickTimelineEvent(event: ClickTimelineEvent): void {
  if (
    !isFinitePositiveBbox(event.targetBboxAtPathStart) ||
    !isFinitePositiveBbox(event.targetBboxAtCommit)
  )
    throw new Error(`${event.id} has an invalid target bbox`);
  if (!bboxContainsPoint(event.targetBboxAtCommit, event.clickPoint))
    throw new Error(`${event.id} click point is outside its commit bbox`);
  validatePath(event.id, event.cursorPath, event.clickPoint);
  if (
    !(
      event.startMs === event.cursorPath[0]?.timeMs &&
      event.startMs < event.mouseDownMs &&
      event.mouseDownMs <= event.mouseUpMs &&
      event.mouseUpMs <= event.endMs
    )
  )
    throw new Error(`${event.id} click timestamps are out of order`);
}

function validateCursorEvent(event: MoveToTimelineEvent | TypeTimelineEvent): void {
  const destination = event.kind === 'moveTo' ? event.destinationPoint : event.focusPoint;
  validatePath(event.id, event.cursorPath, destination);
  if (!isFinitePositiveBbox(event.targetBboxAtCommit))
    throw new Error(`${event.id} has an invalid commit bbox`);
  if (
    event.startMs !== event.cursorPath[0]?.timeMs ||
    event.endMs < (event.cursorPath.at(-1)?.timeMs ?? 0)
  )
    throw new Error(`${event.id} cursor timestamps are out of order`);
}

export function validateTimelineEvent(event: TimelineEvent): void {
  if (
    !event.id ||
    !Number.isFinite(event.startMs) ||
    !Number.isFinite(event.endMs) ||
    event.startMs < 0
  )
    throw new Error('Invalid timeline event identity or timing');
  if (
    event.actionIndex !== undefined &&
    (!Number.isInteger(event.actionIndex) || event.actionIndex < 0)
  )
    throw new Error(`${event.id} has an invalid action index`);
  if (event.kind === 'click') validateClickTimelineEvent(event);
  else if (event.kind === 'moveTo' || event.kind === 'type') validateCursorEvent(event);
  else if (event.kind === 'scrollTo') {
    if (
      !isFinitePoint(event.initialScroll) ||
      !isFinitePoint(event.finalScroll) ||
      event.observedPositions.some(
        (point) => !isFinitePoint(point) || !Number.isFinite(point.timeMs),
      )
    )
      throw new Error(`${event.id} has invalid scroll positions`);
  } else if (
    event.kind === 'wait' &&
    event.mode === 'visible' &&
    !(event.firstVisibleMs >= event.startMs && event.firstVisibleMs <= event.endMs)
  )
    throw new Error(`${event.id} has invalid visibility timing`);
  if (event.endMs < event.startMs) throw new Error('Invalid timeline event identity or timing');
}

export function validateTimelineDocument(
  document: TimelineDocument,
  captureDurationMs?: number,
): void {
  if (document.schemaVersion !== 1) throw new Error('Unsupported timeline schema version');
  const ids = new Set<string>();
  let previousEnd = 0;
  for (const [index, event] of document.events.entries()) {
    validateTimelineEvent(event);
    if (ids.has(event.id)) throw new Error(`Duplicate timeline event ID ${event.id}`);
    ids.add(event.id);
    if (event.startMs < previousEnd - 1e-7)
      throw new Error(`${event.id} overlaps its preceding action`);
    if (event.actionIndex !== undefined && event.actionIndex !== index)
      throw new Error(`${event.id} action index is not consecutive`);
    if (captureDurationMs !== undefined && event.endMs > captureDurationMs)
      throw new Error(`${event.id} falls outside the capture duration`);
    previousEnd = event.endMs;
  }
}
