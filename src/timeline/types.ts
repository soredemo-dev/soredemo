export interface Point {
  x: number;
  y: number;
}

export interface TimedPoint extends Point {
  timeMs: number;
}

export interface BBox extends Point {
  width: number;
  height: number;
}

export interface ResolvedTestIdTarget {
  strategy: 'testId';
  value: {
    testId: string;
  };
}

export interface ClickTimelineEvent {
  id: string;
  kind: 'click';
  startMs: number;
  endMs: number;
  target: ResolvedTestIdTarget;
  targetBboxAtPathStart: BBox;
  targetBboxAtCommit: BBox;
  clickPoint: Point;
  cursorPath: TimedPoint[];
  mouseDownMs: number;
  mouseUpMs: number;
}

export type TimelineEvent = ClickTimelineEvent;

export interface TimelineDocument {
  schemaVersion: 1;
  events: TimelineEvent[];
}

export interface ObservedPointerEvent {
  type: string;
  epochMs: number;
  clientX: number;
  clientY: number;
  button: number;
  buttons: number;
  targetTestId?: string;
}
