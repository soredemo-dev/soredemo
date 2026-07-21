import { createCanvas } from '@napi-rs/canvas';
import { describe, expect, it } from 'vitest';
import { drawClickFeedback } from '../../src/compositor/click-feedback-renderer.js';
import {
  buildClickFeedbackTrack,
  CLICK_RIPPLE_STYLE,
  SequentialClickFeedbackEvaluator,
} from '../../src/compositor/click-feedback-track.js';
import type { ClickTimelineEvent } from '../../src/timeline/types.js';

function click(id: string, mouseDownMs: number): ClickTimelineEvent {
  return {
    id,
    kind: 'click',
    startMs: mouseDownMs - 100,
    endMs: mouseDownMs + 10,
    target: { strategy: 'testId', value: { testId: 'target' } },
    targetBboxAtPathStart: { x: 90, y: 90, width: 20, height: 20 },
    targetBboxAtCommit: { x: 90, y: 90, width: 20, height: 20 },
    clickPoint: { x: 100, y: 100 },
    cursorPath: [
      { x: 90, y: 90, timeMs: mouseDownMs - 100 },
      { x: 100, y: 100, timeMs: mouseDownMs - 10 },
    ],
    mouseDownMs,
    mouseUpMs: mouseDownMs + 5,
  };
}

describe('click feedback', () => {
  it('uses output-time windows, easing, and deterministic overlap', () => {
    const evaluator = new SequentialClickFeedbackEvaluator(
      buildClickFeedbackTrack([click('a', 100), click('b', 150)]),
    );
    expect(evaluator.evaluate(99)).toEqual([]);
    expect(evaluator.evaluate(100)[0]).toMatchObject({ radius: 3, opacity: 0.55, progress: 0 });
    const overlapping = evaluator.evaluate(160);
    expect(overlapping).toHaveLength(2);
    expect(overlapping[0]?.radius).toBeGreaterThan(CLICK_RIPPLE_STYLE.startRadius);
    expect(evaluator.evaluate(410)).toEqual([]);
  });

  it('projects the center through camera while retaining screen-space ring dimensions', () => {
    const canvas = createCanvas(400, 300);
    const context = canvas.getContext('2d');
    context.fillStyle = '#000';
    context.fillRect(0, 0, 400, 300);
    const ripple = new SequentialClickFeedbackEvaluator(
      buildClickFeedbackTrack([click('a', 100)]),
    ).evaluate(100);
    const rendered = drawClickFeedback(
      context,
      ripple,
      { zoom: 1, centerCssX: 200, centerCssY: 150 },
      { width: 400, height: 300 },
      { x: 0, y: 0, width: 400, height: 300 },
    );
    expect(rendered[0]).toMatchObject({ screenX: 100, screenY: 100, radius: 3 });
    expect(context.lineWidth).toBe(1);
  });

  it('rejects unordered and backward evaluation', () => {
    expect(() => buildClickFeedbackTrack([click('b', 200), click('a', 100)])).toThrow(/ordered/);
    const evaluator = new SequentialClickFeedbackEvaluator(
      buildClickFeedbackTrack([click('a', 100)]),
    );
    evaluator.evaluate(100);
    expect(() => evaluator.evaluate(99)).toThrow(/backward/);
  });
});
