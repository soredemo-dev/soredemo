import type { BrowserContext, Page } from 'playwright';
import type { ObservedPointerEvent } from '../timeline/types.js';

const PROBE_NAMESPACE = '__soredemo_capture_events_v1__';
const EVENT_TYPES = [
  'pointermove',
  'pointerdown',
  'pointerup',
  'click',
  'mousedown',
  'mouseup',
] as const;

export async function installPageInstrumentation(context: BrowserContext): Promise<void> {
  await context.addInitScript(
    ({ namespace, eventTypes }) => {
      const state: { events: ObservedPointerEvent[] } = { events: [] };
      Object.defineProperty(window, namespace, {
        configurable: false,
        enumerable: false,
        value: state,
        writable: false,
      });
      const recordEvent = (event: Event) => {
        if (!(event instanceof MouseEvent)) return;
        const target =
          event.target instanceof Element ? event.target.closest('[data-testid]') : null;
        const targetTestId = target?.getAttribute('data-testid') ?? undefined;
        const runtimeTarget =
          event.target instanceof Element
            ? event.target.closest('[data-soredemo-pointer-target]')
            : null;
        const targetRuntimeId =
          runtimeTarget?.getAttribute('data-soredemo-pointer-target') ?? undefined;
        state.events.push({
          type: event.type,
          epochMs: performance.timeOrigin + performance.now(),
          clientX: event.clientX,
          clientY: event.clientY,
          button: event.button,
          buttons: event.buttons,
          ...(targetTestId ? { targetTestId } : {}),
          ...(targetRuntimeId ? { targetRuntimeId } : {}),
        });
      };
      for (const type of eventTypes) {
        window.addEventListener(type, recordEvent, { capture: true });
      }
      const instrumented = new WeakSet<Element>();
      const instrumentPointerEnter = () => {
        for (const element of document.querySelectorAll('[data-testid]')) {
          if (instrumented.has(element)) continue;
          instrumented.add(element);
          element.addEventListener('pointerenter', recordEvent, { capture: true });
        }
      };
      document.addEventListener('DOMContentLoaded', () => {
        instrumentPointerEnter();
        new MutationObserver(instrumentPointerEnter).observe(document.documentElement, {
          childList: true,
          subtree: true,
        });
      });
    },
    { namespace: PROBE_NAMESPACE, eventTypes: EVENT_TYPES },
  );
}

export async function hideBrowserCursor(page: Page): Promise<void> {
  await page.addStyleTag({ content: '* { cursor: none !important; }' });
}

export async function verifyPageInstrumentation(page: Page): Promise<void> {
  await observedEventCount(page);
}

export async function observedEventCount(page: Page): Promise<number> {
  return page.evaluate((namespace) => {
    const state = (window as unknown as Record<string, { events: ObservedPointerEvent[] }>)[
      namespace
    ];
    if (!state) throw new Error('Soredemo page instrumentation is unavailable');
    return state.events.length;
  }, PROBE_NAMESPACE);
}

export async function readObservedEvents(
  page: Page,
  startIndex = 0,
): Promise<ObservedPointerEvent[]> {
  return page.evaluate(
    ({ namespace, start }) => {
      const state = (window as unknown as Record<string, { events: ObservedPointerEvent[] }>)[
        namespace
      ];
      if (!state) throw new Error('Soredemo page instrumentation is unavailable');
      return state.events.slice(start);
    },
    { namespace: PROBE_NAMESPACE, start: startIndex },
  );
}

export function browserEpochToCaptureTimeMs(
  browserEpochMs: number,
  captureOriginEpochMs: number,
): number {
  const timeMs = browserEpochMs - captureOriginEpochMs;
  if (!Number.isFinite(timeMs)) throw new Error('Browser event timestamp is not finite');
  return timeMs;
}
