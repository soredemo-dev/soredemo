import { performance } from 'node:perf_hooks';
import { setTimeout } from 'node:timers/promises';
import type { Page } from 'playwright';
import type { NormalizedAction, Pace } from '../plan/normalized-plan.js';
import { normalizeRenderError, RenderError } from '../render/errors.js';
import type {
  BBox,
  ClickTimelineEvent,
  MoveToTimelineEvent,
  Point,
  TimelineDocument,
  TimelineEvent,
  TypeTimelineEvent,
} from '../timeline/types.js';
import {
  bboxContainsPoint,
  isFinitePositiveBbox,
  validateTimelineDocument,
} from '../timeline/validation.js';
import { driverMonotonicToBrowserEpochMs } from './clock.js';
import { generateCursorPath, type ViewportBounds } from './cursor-path.js';
import { dispatchMousePath } from './mouse-dispatch.js';
import {
  browserEpochToCaptureTimeMs,
  hideBrowserCursor,
  observedEventCount,
  readObservedEvents,
  verifyPageInstrumentation,
} from './page-instrumentation.js';
import {
  prepareTarget,
  type ResolvedLocator,
  resolveTarget,
  stableTargetBbox,
} from './target-resolver.js';
import type { ClockCalibration } from './types.js';

export interface ActionExecutionContext {
  page: Page;
  startupCalibration: ClockCalibration;
  captureOriginEpochMs: number;
  cursor: Point;
  cssViewport: ViewportBounds;
  signal: AbortSignal;
  pace: Pace;
  onActionFailure?: (error: RenderError) => Promise<void> | void;
  onActionStarted?: (actionIndex: number, action: NormalizedAction) => Promise<void> | void;
  onActionCompleted?: (event: TimelineEvent) => Promise<void> | void;
}

function now(context: ActionExecutionContext): number {
  return (
    driverMonotonicToBrowserEpochMs(performance.now(), context.startupCalibration) -
    context.captureOriginEpochMs
  );
}

function id(index: number, kind: string): string {
  return `${kind}-${String(index + 1).padStart(3, '0')}`;
}

function center(bbox: BBox): Point {
  return { x: Math.round(bbox.x + bbox.width / 2), y: Math.round(bbox.y + bbox.height / 2) };
}

function assertHttpUrl(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch (error) {
    throw new RenderError({
      code: 'NAVIGATION_FAILED',
      stage: 'capturing',
      message: 'Navigation URL is invalid',
      cause: error,
    });
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new RenderError({
      code: 'NAVIGATION_FAILED',
      stage: 'capturing',
      message: 'Navigation URL must use http or https',
      details: { protocol: url.protocol },
    });
  }
  return url.href;
}

async function move(context: ActionExecutionContext, destination: Point) {
  const path = generateCursorPath({
    start: context.cursor,
    end: destination,
    viewport: context.cssViewport,
  });
  const dispatched = await dispatchMousePath({
    mouse: context.page.mouse,
    points: path,
    calibration: context.startupCalibration,
    captureOriginEpochMs: context.captureOriginEpochMs,
  });
  context.cursor = destination;
  return dispatched.cursorPath;
}

async function commitBbox(resolved: ResolvedLocator): Promise<BBox> {
  await setTimeout(180, undefined, { signal: undefined });
  const bbox = await resolved.locator.boundingBox();
  if (!bbox || !isFinitePositiveBbox(bbox))
    throw new Error(`${resolved.description} has no valid commit geometry`);
  return bbox;
}

async function hitTest(resolved: ResolvedLocator, point: Point): Promise<void> {
  const matches = await resolved.locator.evaluate((target, location) => {
    const hit = document.elementFromPoint(location.x, location.y);
    return hit !== null && (hit === target || target.contains(hit));
  }, point);
  if (!matches) throw new Error(`${resolved.description} failed its commit-point hit test`);
}

async function executeMoveTo(
  context: ActionExecutionContext,
  action: Extract<NormalizedAction, { action: 'moveTo' }>,
  actionIndex: number,
): Promise<MoveToTimelineEvent> {
  const resolved = await resolveTarget(context.page, action.target);
  const targetBboxAtPathStart = await prepareTarget(resolved);
  const destinationPoint = center(targetBboxAtPathStart);
  const eventId = id(actionIndex, 'moveTo');
  const eventStart = await observedEventCount(context.page);
  const previousRuntimeId = await resolved.locator.evaluate((element, runtimeId) => {
    const previous = element.getAttribute('data-soredemo-pointer-target');
    element.setAttribute('data-soredemo-pointer-target', runtimeId);
    return previous;
  }, eventId);
  let cursorPath: MoveToTimelineEvent['cursorPath'];
  let targetBboxAtCommit: BBox;
  let pointerEnterObserved = false;
  try {
    cursorPath = await move(context, destinationPoint);
    targetBboxAtCommit = await commitBbox(resolved);
    await hitTest(resolved, destinationPoint);
    const observed = await readObservedEvents(context.page, eventStart);
    pointerEnterObserved = observed.some(
      (event) => event.type === 'pointerenter' && event.targetRuntimeId === eventId,
    );
  } finally {
    await resolved.locator.evaluate((element, previous) => {
      if (previous === null) element.removeAttribute('data-soredemo-pointer-target');
      else element.setAttribute('data-soredemo-pointer-target', previous);
    }, previousRuntimeId);
  }
  return {
    id: eventId,
    actionIndex,
    kind: 'moveTo',
    startMs: cursorPath[0]?.timeMs ?? now(context),
    endMs: now(context),
    target: resolved.target,
    targetBboxAtPathStart,
    targetBboxAtCommit,
    destinationPoint,
    cursorPath,
    pointerEnterObserved,
  };
}

async function executeClick(
  context: ActionExecutionContext,
  action: Extract<NormalizedAction, { action: 'click' }>,
  actionIndex: number,
): Promise<ClickTimelineEvent> {
  const resolved = await resolveTarget(context.page, action.target);
  const targetBboxAtPathStart = await prepareTarget(resolved, { enabled: true });
  const clickPoint = center(targetBboxAtPathStart);
  const eventStart = await observedEventCount(context.page);
  const cursorPath = await move(context, clickPoint);
  const targetBboxAtCommit = await commitBbox(resolved);
  if (!bboxContainsPoint(targetBboxAtCommit, clickPoint))
    throw new Error(`${resolved.description} moved away from its click point`);
  await hitTest(resolved, clickPoint);
  await context.page.mouse.down();
  await context.page.mouse.up();
  const observed = await readObservedEvents(context.page, eventStart);
  const down = observed.find((event) => event.type === 'pointerdown');
  const up = observed.find((event) => event.type === 'pointerup');
  const clicks = observed.filter((event) => event.type === 'click');
  if (!down || !up || clicks.length !== 1)
    throw new Error(`${resolved.description} did not emit one canonical browser click`);
  if (Math.abs(down.clientX - clickPoint.x) > 0.5 || Math.abs(down.clientY - clickPoint.y) > 0.5)
    throw new Error(`${resolved.description} pointer coordinates differ from its click point`);
  const mouseDownMs = browserEpochToCaptureTimeMs(down.epochMs, context.captureOriginEpochMs);
  const mouseUpMs = browserEpochToCaptureTimeMs(up.epochMs, context.captureOriginEpochMs);
  return {
    id: id(actionIndex, 'click'),
    actionIndex,
    kind: 'click',
    startMs: cursorPath[0]?.timeMs ?? now(context),
    endMs: mouseUpMs,
    target: resolved.target,
    targetBboxAtPathStart,
    targetBboxAtCommit,
    clickPoint,
    cursorPath,
    mouseDownMs,
    mouseUpMs,
  };
}

async function executeType(
  context: ActionExecutionContext,
  action: Extract<NormalizedAction, { action: 'type' }>,
  actionIndex: number,
): Promise<TypeTimelineEvent> {
  const resolved = await resolveTarget(context.page, action.target);
  const bbox = await prepareTarget(resolved, { enabled: true });
  const focusPoint = center(bbox);
  const cursorPath = await move(context, focusPoint);
  await hitTest(resolved, focusPoint);
  await context.page.mouse.down();
  await context.page.mouse.up();
  const focusMs = now(context);
  const focused = await resolved.locator.evaluate((element) => element === document.activeElement);
  if (!focused) throw new Error(`${resolved.description} did not receive focus`);
  const input = await resolved.locator.evaluate((element) => ({
    value:
      element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement
        ? element.value
        : null,
    password: element instanceof HTMLInputElement && element.type === 'password',
  }));
  const clearedExistingValue = Boolean(input.value);
  if (clearedExistingValue) {
    await context.page.keyboard.press('ControlOrMeta+A');
    await context.page.keyboard.press('Backspace');
  }
  const perCharacterDelayMs = { fast: 18, balanced: 32, calm: 48 }[context.pace];
  await resolved.locator.pressSequentially(action.text, { delay: perCharacterDelayMs });
  if (input.value !== null) {
    const actual = await resolved.locator.inputValue();
    if (actual !== action.text)
      throw new Error(`${resolved.description} did not receive the expected typed value`);
  }
  const targetBboxAtCommit = await stableTargetBbox(resolved.locator);
  return {
    id: id(actionIndex, 'type'),
    actionIndex,
    kind: 'type',
    startMs: cursorPath[0]?.timeMs ?? focusMs,
    endMs: now(context),
    target: resolved.target,
    targetBboxAtCommit,
    focusPoint,
    cursorPath,
    focusMs,
    focusVerified: focused,
    textLength: action.text.length,
    clearedExistingValue,
    perCharacterDelayMs,
    redacted: input.password,
  };
}

async function executeScroll(
  context: ActionExecutionContext,
  action: Extract<NormalizedAction, { action: 'scrollTo' }>,
  actionIndex: number,
): Promise<TimelineEvent> {
  const startMs = now(context);
  const resolved =
    'target' in action ? await resolveTarget(context.page, action.target) : undefined;
  const initialScroll = await context.page.evaluate(() => ({
    x: window.scrollX,
    y: window.scrollY,
  }));
  const samples = await context.page.evaluate(
    async ({ targetDescription, x, y, durationMs }) => {
      const target = targetDescription
        ? document.querySelector(`[data-soredemo-scroll-target="${targetDescription}"]`)
        : null;
      const positions: Array<{ epochMs: number; x: number; y: number }> = [];
      if (target) target.scrollIntoView({ behavior: 'smooth', block: 'center' });
      else window.scrollTo({ left: x ?? 0, top: y ?? 0, behavior: 'smooth' });
      const started = performance.now();
      let stable = 0;
      let previousX = Number.NaN;
      let previousY = Number.NaN;
      while (performance.now() - started < durationMs + 3000) {
        await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
        if (positions.length < 120)
          positions.push({
            epochMs: performance.timeOrigin + performance.now(),
            x: window.scrollX,
            y: window.scrollY,
          });
        if (window.scrollX === previousX && window.scrollY === previousY) stable += 1;
        else stable = 0;
        previousX = window.scrollX;
        previousY = window.scrollY;
        if (stable >= 5 && performance.now() - started >= Math.min(durationMs, 150)) break;
      }
      return positions;
    },
    await (async () => {
      if (resolved) {
        const token = `scroll-${actionIndex}`;
        await resolved.locator.evaluate(
          (element, value) => element.setAttribute('data-soredemo-scroll-target', value),
          token,
        );
        return { targetDescription: token, x: null, y: null, durationMs: action.durationMs };
      }
      if ('target' in action) throw new Error('SCROLL_INVALID: Target scroll was not resolved');
      return { targetDescription: null, x: action.x, y: action.y, durationMs: action.durationMs };
    })(),
  );
  if (resolved)
    await resolved.locator.evaluate((element) =>
      element.removeAttribute('data-soredemo-scroll-target'),
    );
  const finalScroll = await context.page.evaluate(() => ({ x: window.scrollX, y: window.scrollY }));
  const observedPositions = samples.map((sample) => ({
    x: sample.x,
    y: sample.y,
    timeMs: browserEpochToCaptureTimeMs(sample.epochMs, context.captureOriginEpochMs),
  }));
  const targetBboxAtCommit = resolved ? await stableTargetBbox(resolved.locator) : undefined;
  const base = {
    id: id(actionIndex, 'scrollTo'),
    actionIndex,
    kind: 'scrollTo' as const,
    startMs,
    endMs: now(context),
    initialScroll,
    finalScroll,
    observedPositions,
  };
  if (resolved) {
    if (!targetBboxAtCommit) throw new Error('TARGET_INVALID: Scroll target lost its geometry');
    return { ...base, target: resolved.target, targetBboxAtCommit };
  }
  if ('target' in action) throw new Error('SCROLL_INVALID: Target scroll was not resolved');
  return { ...base, requestedPosition: { x: action.x, y: action.y } };
}

export async function executeActions(
  context: ActionExecutionContext,
  actions: readonly NormalizedAction[],
  onCompleted?: (count: number) => Promise<void> | void,
): Promise<TimelineDocument> {
  const events: TimelineEvent[] = [];
  for (const [actionIndex, action] of actions.entries()) {
    if (context.signal.aborted) throw new Error('RENDER_ABORTED: Render was interrupted');
    try {
      await context.onActionStarted?.(actionIndex, action);
      let event: TimelineEvent;
      if (action.action === 'moveTo') event = await executeMoveTo(context, action, actionIndex);
      else if (action.action === 'click') event = await executeClick(context, action, actionIndex);
      else if (action.action === 'type') event = await executeType(context, action, actionIndex);
      else if (action.action === 'scrollTo')
        event = await executeScroll(context, action, actionIndex);
      else if (action.action === 'goto') {
        const startMs = now(context);
        const requestedUrl = assertHttpUrl(action.url);
        try {
          await context.page.goto(requestedUrl, {
            waitUntil: 'domcontentloaded',
            timeout: 30_000,
          });
        } catch (error) {
          throw new RenderError({
            code: 'NAVIGATION_FAILED',
            stage: 'capturing',
            message: error instanceof Error ? error.message : String(error),
            cause: error,
          });
        }
        await hideBrowserCursor(context.page);
        await verifyPageInstrumentation(context.page);
        await setTimeout(300);
        event = {
          id: id(actionIndex, 'goto'),
          actionIndex,
          kind: 'goto',
          startMs,
          endMs: now(context),
          requestedUrl,
          finalUrl: context.page.url(),
        };
      } else if ('durationMs' in action) {
        const startMs = now(context);
        await setTimeout(action.durationMs, undefined, { signal: context.signal });
        event = {
          id: id(actionIndex, 'wait'),
          actionIndex,
          kind: 'wait',
          mode: 'duration',
          startMs,
          endMs: now(context),
          requestedDurationMs: action.durationMs,
        };
      } else {
        const startMs = now(context);
        const resolved = await resolveTarget(context.page, action.until.visible);
        try {
          await resolved.locator.waitFor({ state: 'visible', timeout: action.timeoutMs });
        } catch (error) {
          throw new RenderError({
            code: 'ACTION_TIMEOUT',
            stage: 'capturing',
            message: error instanceof Error ? error.message : String(error),
            targetDescription: resolved.description,
            cause: error,
          });
        }
        const firstVisibleMs = now(context);
        await setTimeout(action.settleMs, undefined, { signal: context.signal });
        if (!(await resolved.locator.isVisible()))
          throw new RenderError({
            code: 'ACTION_TIMEOUT',
            stage: 'capturing',
            message: 'Target did not remain visible through settle interval',
            targetDescription: resolved.description,
          });
        event = {
          id: id(actionIndex, 'wait'),
          actionIndex,
          kind: 'wait',
          mode: 'visible',
          startMs,
          endMs: now(context),
          target: resolved.target,
          timeoutMs: action.timeoutMs,
          settleMs: action.settleMs,
          firstVisibleMs,
        };
      }
      events.push(event);
      await context.onActionCompleted?.(event);
      await onCompleted?.(events.length);
    } catch (error) {
      const normalized = normalizeRenderError(error, {
        code: 'ACTION_FAILED',
        stage: 'capturing',
      });
      const actionError = new RenderError({
        code: normalized.code,
        stage: normalized.stage,
        message: normalized.message,
        actionIndex,
        actionKind: action.action,
        ...(normalized.targetDescription
          ? { targetDescription: normalized.targetDescription }
          : {}),
        ...(normalized.details ? { details: normalized.details } : {}),
        cause: error,
      });
      await context.onActionFailure?.(actionError);
      throw actionError;
    }
  }
  const timeline: TimelineDocument = { schemaVersion: 1, events };
  validateTimelineDocument(timeline);
  return timeline;
}
