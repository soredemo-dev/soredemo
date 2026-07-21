import { setTimeout } from 'node:timers/promises';
import type { Locator, Page } from 'playwright';
import type { BBox, ClickTimelineEvent, ObservedPointerEvent, Point } from '../timeline/types.js';
import {
  bboxChangeCssPx,
  bboxContainsPoint,
  isFinitePositiveBbox,
  validateClickTimelineEvent,
} from '../timeline/validation.js';
import { generateCursorPath, type ViewportBounds } from './cursor-path.js';
import { dispatchMousePath } from './mouse-dispatch.js';
import {
  browserEpochToCaptureTimeMs,
  observedEventCount,
  readObservedEvents,
} from './page-instrumentation.js';
import type { ClockCalibration } from './types.js';

export interface RecordedClickDiagnostics {
  moveRoundTripMs: number[];
  pointerDownCoordinateErrorCssPx: number;
  bboxChangeCssPx: number;
  pointerEnterObserved: boolean;
  observedEvents: ObservedPointerEvent[];
}

export interface RecordedClick {
  event: ClickTimelineEvent;
  diagnostics: RecordedClickDiagnostics;
  cursorPosition: Point;
}

export interface HitTestResult {
  hitFound: boolean;
  hitIsTarget: boolean;
  targetContainsHit: boolean;
}

export function hitTestMatchesTarget(result: HitTestResult): boolean {
  return result.hitFound && (result.hitIsTarget || result.targetContainsHit);
}

function bboxDifference(left: BBox, right: BBox): number {
  return Math.max(
    Math.abs(left.x - right.x),
    Math.abs(left.y - right.y),
    Math.abs(left.width - right.width),
    Math.abs(left.height - right.height),
  );
}

async function stableBbox(locator: Locator, tolerancePx = 0.25): Promise<BBox> {
  for (let attempt = 1; attempt <= 12; attempt += 1) {
    const samples = await locator.evaluate(async (element) => {
      const values: BBox[] = [];
      for (let sample = 0; sample < 4; sample += 1) {
        await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
        const rect = element.getBoundingClientRect();
        values.push({ x: rect.x, y: rect.y, width: rect.width, height: rect.height });
      }
      return values;
    });
    if (
      samples.length === 4 &&
      samples.slice(1).every((sample, index) => {
        const previous = samples[index];
        return previous ? bboxDifference(previous, sample) <= tolerancePx : false;
      })
    ) {
      const bbox = samples.at(-1);
      if (bbox && isFinitePositiveBbox(bbox)) return bbox;
    }
    await setTimeout(25);
  }
  throw new Error('Target bbox did not stabilize within 12 four-frame samples');
}

function eventsOfType(
  events: ObservedPointerEvent[],
  type: string,
  testId: string,
): ObservedPointerEvent[] {
  return events.filter((event) => event.type === type && event.targetTestId === testId);
}

async function applicationClickCount(locator: Locator): Promise<number> {
  return locator.evaluate((element) =>
    Number(element.getAttribute('data-application-clicks') ?? 0),
  );
}

export async function recordFixtureClick(options: {
  id: string;
  page: Page;
  testId: string;
  cursorPosition: Point;
  viewport: ViewportBounds;
  startupCalibration: ClockCalibration;
  captureOriginEpochMs: number;
  requirePointerEnter: boolean;
  requireBboxChange: boolean;
}): Promise<RecordedClick> {
  const locator = options.page.getByTestId(options.testId);
  await locator.scrollIntoViewIfNeeded();
  await locator.waitFor({ state: 'visible' });
  if (!(await locator.isEnabled())) throw new Error(`${options.id} target is disabled`);
  const targetBboxAtPathStart = await stableBbox(locator);
  const clickPoint = {
    x: Math.round(targetBboxAtPathStart.x + targetBboxAtPathStart.width / 2),
    y: Math.round(targetBboxAtPathStart.y + targetBboxAtPathStart.height / 2),
  };
  const plannedPath = generateCursorPath({
    start: options.cursorPosition,
    end: clickPoint,
    viewport: options.viewport,
  });
  const observedStartIndex = await observedEventCount(options.page);
  const applicationClicksBefore = await applicationClickCount(locator);
  const dispatched = await dispatchMousePath({
    mouse: options.page.mouse,
    points: plannedPath,
    calibration: options.startupCalibration,
    captureOriginEpochMs: options.captureOriginEpochMs,
  });

  await setTimeout(180);
  const targetBboxAtCommit = await locator.boundingBox();
  if (!targetBboxAtCommit || !isFinitePositiveBbox(targetBboxAtCommit)) {
    throw new Error(`${options.id} has no valid commit bbox`);
  }
  if (!bboxContainsPoint(targetBboxAtCommit, clickPoint)) {
    throw new Error(`${options.id} click point left its target after hover`);
  }
  const hitTestResult = await locator.evaluate((target, point): HitTestResult => {
    const hit = document.elementFromPoint(point.x, point.y);
    return {
      hitFound: hit !== null,
      hitIsTarget: hit === target,
      targetContainsHit: hit !== null && target.contains(hit),
    };
  }, clickPoint);
  if (!hitTestMatchesTarget(hitTestResult)) {
    throw new Error(`${options.id} failed its commit-point hit test`);
  }

  await options.page.mouse.down();
  await options.page.mouse.up();
  const observedEvents = await readObservedEvents(options.page, observedStartIndex);
  const applicationClicksAfter = await applicationClickCount(locator);
  if (applicationClicksAfter - applicationClicksBefore !== 1) {
    throw new Error(`${options.id} did not produce exactly one application click`);
  }

  const pointerDownEvents = eventsOfType(observedEvents, 'pointerdown', options.testId);
  const pointerUpEvents = eventsOfType(observedEvents, 'pointerup', options.testId);
  const clickEvents = eventsOfType(observedEvents, 'click', options.testId);
  const mouseDownEvents = eventsOfType(observedEvents, 'mousedown', options.testId);
  const mouseUpEvents = eventsOfType(observedEvents, 'mouseup', options.testId);
  if (
    pointerDownEvents.length !== 1 ||
    pointerUpEvents.length !== 1 ||
    clickEvents.length !== 1 ||
    mouseDownEvents.length !== 1 ||
    mouseUpEvents.length !== 1
  ) {
    throw new Error(`${options.id} browser event cardinality is invalid`);
  }
  const pointerDown = pointerDownEvents[0];
  const pointerUp = pointerUpEvents[0];
  if (!pointerDown || !pointerUp) throw new Error(`${options.id} is missing canonical events`);
  const coordinateError = Math.hypot(
    pointerDown.clientX - clickPoint.x,
    pointerDown.clientY - clickPoint.y,
  );
  if (
    Math.abs(pointerDown.clientX - clickPoint.x) > 0.5 ||
    Math.abs(pointerDown.clientY - clickPoint.y) > 0.5
  ) {
    throw new Error(`${options.id} pointer-down coordinate differs from its click point`);
  }

  const pointerEnterObserved =
    eventsOfType(observedEvents, 'pointerenter', options.testId).length > 0;
  if (options.requirePointerEnter && !pointerEnterObserved) {
    throw new Error(`${options.id} did not observe pointerenter on its hover target`);
  }
  const bboxChange = bboxChangeCssPx(targetBboxAtPathStart, targetBboxAtCommit);
  if (options.requireBboxChange && bboxChange <= 1) {
    throw new Error(`${options.id} hover target bbox did not measurably change`);
  }

  const mouseDownMs = browserEpochToCaptureTimeMs(
    pointerDown.epochMs,
    options.captureOriginEpochMs,
  );
  const mouseUpMs = browserEpochToCaptureTimeMs(pointerUp.epochMs, options.captureOriginEpochMs);
  const firstPathPoint = dispatched.cursorPath[0];
  if (!firstPathPoint) throw new Error(`${options.id} has no dispatched cursor path`);
  const event: ClickTimelineEvent = {
    id: options.id,
    kind: 'click',
    startMs: firstPathPoint.timeMs,
    endMs: mouseUpMs,
    target: { strategy: 'testId', value: { testId: options.testId } },
    targetBboxAtPathStart,
    targetBboxAtCommit,
    clickPoint,
    cursorPath: dispatched.cursorPath,
    mouseDownMs,
    mouseUpMs,
  };
  validateClickTimelineEvent(event);

  return {
    event,
    diagnostics: {
      moveRoundTripMs: dispatched.roundTripMs,
      pointerDownCoordinateErrorCssPx: coordinateError,
      bboxChangeCssPx: bboxChange,
      pointerEnterObserved,
      observedEvents,
    },
    cursorPosition: clickPoint,
  };
}
