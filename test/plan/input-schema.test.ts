import { describe, expect, it } from 'vitest';
import { ScriptInputSchema, TargetInputSchema } from '../../src/plan/input-schema.js';

const basePlan = {
  version: 1,
  name: 'schema-test',
  url: 'http://127.0.0.1:4173/',
  intent: { goal: 'Exercise the schema', targetDurationMs: 12_000 },
  actions: [{ action: 'wait', durationMs: 300 }],
};

describe('TargetInputSchema', () => {
  it.each([
    { role: 'button', name: 'Create' },
    { label: 'Project name' },
    { testId: 'create-button' },
    { text: 'Create', exact: true },
    { css: '#create-button' },
  ])('accepts one semantic strategy: %j', (target) => {
    expect(TargetInputSchema.safeParse(target).success).toBe(true);
  });

  it('rejects mixed semantic strategies', () => {
    expect(TargetInputSchema.safeParse({ role: 'button', css: '#create' }).success).toBe(false);
  });
});

describe('ScriptInputSchema', () => {
  it('accepts all six action kinds and both wait forms', () => {
    const result = ScriptInputSchema.safeParse({
      ...basePlan,
      actions: [
        { action: 'goto', url: 'http://127.0.0.1:4173/workspace' },
        { action: 'wait', durationMs: 300 },
        {
          action: 'wait',
          until: { visible: { role: 'heading', name: 'Dashboard' } },
        },
        { action: 'moveTo', target: { text: 'Preview' } },
        { action: 'click', target: { role: 'button', name: 'Create' } },
        { action: 'type', target: { label: 'Project name' }, text: 'Soredemo' },
        { action: 'scrollTo', target: { role: 'heading', name: 'Analytics' }, durationMs: 700 },
      ],
    });

    expect(result.success).toBe(true);
  });

  it('accepts coordinate scrolling without x', () => {
    const result = ScriptInputSchema.safeParse({
      ...basePlan,
      actions: [{ action: 'scrollTo', y: 1200, durationMs: 700 }],
    });

    expect(result.success).toBe(true);
  });

  it('rejects scroll actions that mix a target and coordinates', () => {
    const result = ScriptInputSchema.safeParse({
      ...basePlan,
      actions: [
        {
          action: 'scrollTo',
          target: { text: 'Analytics' },
          x: 0,
          y: 1200,
          durationMs: 700,
        },
      ],
    });

    expect(result.success).toBe(false);
  });

  it('rejects the retired intent duration field', () => {
    const result = ScriptInputSchema.safeParse({
      ...basePlan,
      intent: { goal: 'Exercise the schema', durationMs: 12_000 },
    });

    expect(result.success).toBe(false);
  });
});
