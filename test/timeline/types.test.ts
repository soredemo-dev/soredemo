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
});
