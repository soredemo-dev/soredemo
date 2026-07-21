import { describe, expect, it } from 'vitest';
import type { ClickTimelineEvent, TimelineDocument } from '../../src/timeline/types.js';
import { bboxContainsPoint, validateTimelineDocument } from '../../src/timeline/validation.js';

function clickEvent(id = 'click-001'): ClickTimelineEvent {
  return {
    id,
    kind: 'click',
    startMs: 100,
    endMs: 300,
    target: { strategy: 'testId', value: { testId: 'static-target' } },
    targetBboxAtPathStart: { x: 10, y: 20, width: 100, height: 40 },
    targetBboxAtCommit: { x: 5, y: 15, width: 110, height: 50 },
    clickPoint: { x: 60, y: 40 },
    cursorPath: [
      { x: 0, y: 0, timeMs: 100 },
      { x: 60, y: 40, timeMs: 250 },
    ],
    mouseDownMs: 275,
    mouseUpMs: 300,
  };
}

describe('timeline contracts', () => {
  it('uses inclusive viewport-relative bbox containment', () => {
    expect(bboxContainsPoint({ x: 10, y: 20, width: 30, height: 40 }, { x: 40, y: 60 })).toBe(true);
  });

  it('validates unique click events within the capture duration', () => {
    const document: TimelineDocument = { schemaVersion: 1, events: [clickEvent()] };
    expect(() => validateTimelineDocument(document, 400)).not.toThrow();
  });

  it('rejects duplicate event IDs and non-increasing paths', () => {
    const invalid = clickEvent();
    invalid.cursorPath[1] = { x: 60, y: 40, timeMs: 100 };
    expect(() => validateTimelineDocument({ schemaVersion: 1, events: [invalid] }, 400)).toThrow(
      'strictly increasing',
    );
    expect(() =>
      validateTimelineDocument({ schemaVersion: 1, events: [clickEvent(), clickEvent()] }, 400),
    ).toThrow('Duplicate');
  });

  it('validates consecutive action indexes across all six event variants', () => {
    const target = { strategy: 'testId' as const, value: { testId: 'target' } };
    const bbox = { x: 10, y: 10, width: 40, height: 20 };
    const document: TimelineDocument = {
      schemaVersion: 1,
      events: [
        {
          id: 'wait-001',
          actionIndex: 0,
          kind: 'wait',
          mode: 'duration',
          startMs: 0,
          endMs: 10,
          requestedDurationMs: 10,
        },
        {
          id: 'goto-002',
          actionIndex: 1,
          kind: 'goto',
          startMs: 10,
          endMs: 20,
          requestedUrl: 'http://127.0.0.1/',
          finalUrl: 'http://127.0.0.1/',
        },
        {
          id: 'moveTo-003',
          actionIndex: 2,
          kind: 'moveTo',
          startMs: 20,
          endMs: 40,
          target,
          targetBboxAtPathStart: bbox,
          targetBboxAtCommit: bbox,
          destinationPoint: { x: 30, y: 20 },
          cursorPath: [
            { x: 0, y: 0, timeMs: 20 },
            { x: 30, y: 20, timeMs: 35 },
          ],
          pointerEnterObserved: true,
        },
        {
          ...clickEvent('click-004'),
          actionIndex: 3,
          startMs: 40,
          endMs: 60,
          cursorPath: [
            { x: 30, y: 20, timeMs: 40 },
            { x: 60, y: 40, timeMs: 50 },
          ],
          mouseDownMs: 55,
          mouseUpMs: 60,
        },
        {
          id: 'type-005',
          actionIndex: 4,
          kind: 'type',
          startMs: 60,
          endMs: 90,
          target,
          targetBboxAtCommit: bbox,
          focusPoint: { x: 30, y: 20 },
          cursorPath: [
            { x: 60, y: 40, timeMs: 60 },
            { x: 30, y: 20, timeMs: 70 },
          ],
          focusMs: 75,
          focusVerified: true,
          textLength: 8,
          clearedExistingValue: false,
          perCharacterDelayMs: 32,
          redacted: false,
        },
        {
          id: 'scrollTo-006',
          actionIndex: 5,
          kind: 'scrollTo',
          startMs: 90,
          endMs: 110,
          requestedPosition: { x: 0, y: 500 },
          initialScroll: { x: 0, y: 0 },
          finalScroll: { x: 0, y: 500 },
          observedPositions: [{ x: 0, y: 500, timeMs: 100 }],
        },
      ],
    };

    expect(() => validateTimelineDocument(document, 120)).not.toThrow();
    expect(document.events.map((event) => event.kind)).toEqual([
      'wait',
      'goto',
      'moveTo',
      'click',
      'type',
      'scrollTo',
    ]);
  });
});
