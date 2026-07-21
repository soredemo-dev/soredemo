import { describe, expect, it } from 'vitest';
import { SequentialCursorEvaluator } from '../../src/compositor/cursor-track.js';
import { buildCursorTrack } from '../../src/timeline/cursor-track-validation.js';
import type { ClickTimelineEvent } from '../../src/timeline/types.js';

function click(
  id: string,
  points: Array<{ x: number; y: number; timeMs: number }>,
): ClickTimelineEvent {
  const first = points[0];
  const final = points.at(-1);
  if (!first || !final) throw new Error('Test path is empty');
  return {
    id,
    kind: 'click',
    startMs: first.timeMs,
    endMs: final.timeMs + 20,
    target: { strategy: 'testId', value: { testId: 'static-target' } },
    targetBboxAtPathStart: { x: 0, y: 0, width: 100, height: 100 },
    targetBboxAtCommit: { x: 0, y: 0, width: 100, height: 100 },
    clickPoint: { x: final.x, y: final.y },
    cursorPath: points,
    mouseDownMs: final.timeMs + 10,
    mouseUpMs: final.timeMs + 11,
  };
}

describe('recorded cursor track', () => {
  it('evaluates hidden, exact, linear, boundary, and held states sequentially', () => {
    const events = [
      click('click-001', [
        { x: 0, y: 0, timeMs: 100 },
        { x: 10, y: 10, timeMs: 200 },
      ]),
      click('click-002', [
        { x: 10, y: 10, timeMs: 400 },
        { x: 20, y: 0, timeMs: 500 },
      ]),
    ];
    const track = buildCursorTrack(events, { width: 100, height: 100 });
    expect(track.movements[0]?.points).toBe(events[0]?.cursorPath);
    expect(track.pointCount).toBe(4);
    const evaluator = new SequentialCursorEvaluator(track);
    expect(evaluator.evaluate(0)).toEqual({ visible: false, interpolation: 'hidden' });
    expect(evaluator.evaluate(100).interpolation).toBe('exact');
    expect(evaluator.evaluate(150)).toMatchObject({
      cssX: 5,
      cssY: 5,
      interpolation: 'linear',
    });
    expect(evaluator.evaluate(200).interpolation).toBe('exact');
    expect(evaluator.evaluate(300)).toMatchObject({ cssX: 10, cssY: 10, interpolation: 'held' });
    expect(evaluator.evaluate(400)).toMatchObject({
      cssX: 10,
      cssY: 10,
      activeClickId: 'click-002',
      interpolation: 'exact',
    });
    expect(evaluator.evaluate(450).interpolation).toBe('linear');
    expect(evaluator.evaluate(500).interpolation).toBe('exact');
    expect(evaluator.evaluate(1000).interpolation).toBe('held');
  });

  it('rejects overlaps, backward points, viewport escapes, endpoint mismatch, and jumps', () => {
    const first = click('click-001', [
      { x: 0, y: 0, timeMs: 100 },
      { x: 10, y: 10, timeMs: 200 },
    ]);
    expect(() =>
      buildCursorTrack(
        [
          first,
          click('click-002', [
            { x: 10, y: 10, timeMs: 150 },
            { x: 20, y: 20, timeMs: 250 },
          ]),
        ],
        { width: 100, height: 100 },
      ),
    ).toThrow('overlaps');

    const backward = click('click-003', [
      { x: 0, y: 0, timeMs: 200 },
      { x: 10, y: 10, timeMs: 100 },
    ]);
    expect(() => buildCursorTrack([backward], { width: 100, height: 100 })).toThrow(
      'strictly increasing',
    );
    const outside = click('click-004', [
      { x: 0, y: 0, timeMs: 100 },
      { x: 101, y: 10, timeMs: 200 },
    ]);
    outside.targetBboxAtPathStart.width = 200;
    outside.targetBboxAtCommit.width = 200;
    expect(() => buildCursorTrack([outside], { width: 100, height: 100 })).toThrow('viewport');
    const mismatch = { ...first, clickPoint: { x: 9, y: 9 } };
    expect(() => buildCursorTrack([mismatch], { width: 100, height: 100 })).toThrow(
      'does not equal',
    );
    const jumping = click('click-005', [
      { x: 11, y: 10, timeMs: 300 },
      { x: 20, y: 20, timeMs: 400 },
    ]);
    expect(() => buildCursorTrack([first, jumping], { width: 100, height: 100 })).toThrow('jumps');
  });

  it('rejects backward evaluation time', () => {
    const evaluator = new SequentialCursorEvaluator(
      buildCursorTrack(
        [
          click('click-001', [
            { x: 0, y: 0, timeMs: 100 },
            { x: 10, y: 10, timeMs: 200 },
          ]),
        ],
        { width: 100, height: 100 },
      ),
    );
    evaluator.evaluate(150);
    expect(() => evaluator.evaluate(149)).toThrow('moved backward');
  });
});
