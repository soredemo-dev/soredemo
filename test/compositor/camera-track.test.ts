import { describe, expect, it } from 'vitest';
import { SequentialCameraEvaluator } from '../../src/compositor/camera-evaluator.js';
import { STUDIO_CAMERA_POLICY } from '../../src/compositor/camera-policy.js';
import { buildCameraTrack } from '../../src/compositor/camera-track.js';
import type { ClickTimelineEvent } from '../../src/timeline/types.js';

const viewport = { width: 1440, height: 900 };

function click(id: string, startMs: number, mouseDownMs: number, x: number): ClickTimelineEvent {
  const bbox = { x, y: 300, width: 100, height: 40 };
  const point = { x: x + 50, y: 320 };
  return {
    id,
    kind: 'click',
    startMs,
    endMs: mouseDownMs + 10,
    target: { strategy: 'testId', value: { testId: 'target' } },
    targetBboxAtPathStart: bbox,
    targetBboxAtCommit: bbox,
    clickPoint: point,
    cursorPath: [
      { ...point, timeMs: startMs },
      { ...point, timeMs: mouseDownMs - 20 },
    ],
    mouseDownMs,
    mouseUpMs: mouseDownMs + 5,
  };
}

describe('camera track and evaluator', () => {
  it('builds non-overlapping transition and hold segments', () => {
    const track = buildCameraTrack(
      [click('click-1', 1000, 1600, 200), click('click-2', 3000, 3600, 1100)],
      5000,
      viewport,
    );
    expect(track.transitions).toHaveLength(2);
    expect(track.segments[0]?.phase).toBe('establish');
    for (let index = 1; index < track.segments.length; index += 1) {
      expect(track.segments[index]?.startMs).toBe(track.segments[index - 1]?.endMs);
    }
    expect(track.segments.at(-1)?.endMs).toBe(5000);
  });

  it('compresses only when the click window cannot fit the minimum', () => {
    const track = buildCameraTrack([click('click-1', 610, 800, 200)], 1200, viewport);
    expect(track.transitions[0]?.compressed).toBe(true);
    expect((track.transitions[0]?.endMs ?? 0) - (track.transitions[0]?.startMs ?? 0)).toBeLessThan(
      STUDIO_CAMERA_POLICY.transitionMinMs,
    );
  });

  it('eases at output time and is continuous at segment boundaries', () => {
    const track = buildCameraTrack([click('click-1', 1000, 1800, 200)], 2500, viewport);
    const transition = track.transitions[0];
    if (!transition) throw new Error('missing transition');
    const evaluator = new SequentialCameraEvaluator(track);
    const start = evaluator.evaluate(transition.startMs);
    const middle = evaluator.evaluate((transition.startMs + transition.endMs) / 2);
    const end = evaluator.evaluate(transition.endMs);
    expect(start.zoom).toBe(transition.from.zoom);
    expect(middle.easedProgress).toBeGreaterThan(middle.linearProgress ?? 1);
    expect(end.zoom).toBeCloseTo(transition.to.zoom, 12);
    expect(end.centerCssX).toBeCloseTo(transition.to.centerCssX, 12);
    expect(end.phase).toBe('hold');
  });

  it('rejects backward ordered evaluation', () => {
    const evaluator = new SequentialCameraEvaluator(
      buildCameraTrack([click('click-1', 1000, 1800, 200)], 2500, viewport),
    );
    evaluator.evaluate(1000);
    expect(() => evaluator.evaluate(999)).toThrow(/backward/);
  });

  it('has no state discontinuity at any segment boundary', () => {
    const track = buildCameraTrack(
      [click('click-1', 1000, 1800, 200), click('click-2', 3000, 3800, 1100)],
      5000,
      viewport,
    );
    for (let index = 1; index < track.segments.length; index += 1) {
      const previous = track.segments[index - 1];
      const current = track.segments[index];
      if (!previous || !current) continue;
      const previousState = previous.phase === 'transition' ? previous.to : previous.state;
      const currentState = current.phase === 'transition' ? current.from : current.state;
      expect(currentState).toEqual(previousState);
    }
  });
});
