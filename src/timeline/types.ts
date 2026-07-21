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

export type ResolvedTargetStrategy = 'role' | 'label' | 'testId' | 'text' | 'css';

export interface ResolvedTarget {
  strategy: ResolvedTargetStrategy;
  value: Record<string, string | boolean | null>;
}

export interface TimelineEventBase {
  id: string;
  actionIndex?: number;
  kind: 'goto' | 'wait' | 'moveTo' | 'click' | 'type' | 'scrollTo';
  startMs: number;
  endMs: number;
}

export interface GotoTimelineEvent extends TimelineEventBase {
  kind: 'goto';
  requestedUrl: string;
  finalUrl: string;
}

export interface DurationWaitTimelineEvent extends TimelineEventBase {
  kind: 'wait';
  mode: 'duration';
  requestedDurationMs: number;
}

export interface VisibleWaitTimelineEvent extends TimelineEventBase {
  kind: 'wait';
  mode: 'visible';
  target: ResolvedTarget;
  timeoutMs: number;
  settleMs: number;
  firstVisibleMs: number;
}

export type WaitTimelineEvent = DurationWaitTimelineEvent | VisibleWaitTimelineEvent;

export interface MoveToTimelineEvent extends TimelineEventBase {
  kind: 'moveTo';
  target: ResolvedTarget;
  targetBboxAtPathStart: BBox;
  targetBboxAtCommit: BBox;
  destinationPoint: Point;
  cursorPath: TimedPoint[];
  pointerEnterObserved: boolean;
}

export interface ClickTimelineEvent extends TimelineEventBase {
  kind: 'click';
  target: ResolvedTarget;
  targetBboxAtPathStart: BBox;
  targetBboxAtCommit: BBox;
  clickPoint: Point;
  cursorPath: TimedPoint[];
  mouseDownMs: number;
  mouseUpMs: number;
}

export interface TypeTimelineEvent extends TimelineEventBase {
  kind: 'type';
  target: ResolvedTarget;
  targetBboxAtCommit: BBox;
  focusPoint: Point;
  cursorPath: TimedPoint[];
  focusMs: number;
  focusVerified: boolean;
  textLength: number;
  clearedExistingValue: boolean;
  perCharacterDelayMs: number;
  redacted: boolean;
}

export interface ScrollToTimelineEvent extends TimelineEventBase {
  kind: 'scrollTo';
  target?: ResolvedTarget;
  requestedPosition?: Point;
  targetBboxAtCommit?: BBox;
  initialScroll: Point;
  finalScroll: Point;
  observedPositions: TimedPoint[];
}

export type TimelineEvent =
  | GotoTimelineEvent
  | WaitTimelineEvent
  | MoveToTimelineEvent
  | ClickTimelineEvent
  | TypeTimelineEvent
  | ScrollToTimelineEvent;

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
  targetRuntimeId?: string;
}
