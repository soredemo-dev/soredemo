import { describe, expect, it } from 'vitest';
import type { ScriptInput } from '../../src/plan/input-schema.js';
import { normalizeScript } from '../../src/plan/normalize.js';

const input: ScriptInput = {
  version: 1,
  name: 'normalization-test',
  url: 'http://127.0.0.1:4173/',
  intent: { goal: 'Exercise normalization', targetDurationMs: 8_000 },
  actions: [
    { action: 'click', target: { text: 'Create' } },
    { action: 'wait', until: { visible: { role: 'heading', name: 'Created' } } },
    { action: 'scrollTo', y: 1200, durationMs: 700 },
  ],
};

describe('normalizeScript', () => {
  it('applies stable defaults outside the input schema', () => {
    const plan = normalizeScript(input);

    expect(plan.viewport).toEqual({ width: 1440, height: 900 });
    expect(plan.style).toEqual({ preset: 'studio', pace: 'balanced', seed: 0 });
    expect(plan.intent.targetDurationMs).toBe(8_000);
    expect(plan.actions[0]).toEqual({
      action: 'click',
      target: { text: 'Create', exact: false },
      emphasis: 'none',
      focusAfter: null,
    });
    expect(plan.actions[1]).toEqual({
      action: 'wait',
      until: { visible: { role: 'heading', name: 'Created' } },
      timeoutMs: 10_000,
      settleMs: 500,
    });
    expect(plan.actions[2]).toEqual({
      action: 'scrollTo',
      x: 0,
      y: 1200,
      durationMs: 700,
    });
  });
});
