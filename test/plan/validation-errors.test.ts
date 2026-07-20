import { describe, expect, it } from 'vitest';
import {
  formatValidationHuman,
  formatValidationJson,
  validationDiagnostics,
} from '../../src/cli/output/validation.js';
import { DemoPlanValidationError } from '../../src/plan/errors.js';
import { ScriptInputSchema } from '../../src/plan/input-schema.js';

function invalidPlanError(): DemoPlanValidationError {
  const input = {
    version: 1,
    name: 'invalid',
    url: 'http://127.0.0.1:4173/',
    intent: { goal: 'Test errors' },
    actions: [{ action: 'click', emphasis: 'primary' }],
  };
  const result = ScriptInputSchema.safeParse(input);
  if (result.success) throw new Error('Expected fixture to be invalid');
  return new DemoPlanValidationError(result.error.issues, input);
}

describe('validation diagnostics', () => {
  it('preserves a stable structured path', () => {
    expect(validationDiagnostics(invalidPlanError())).toEqual([
      {
        path: ['actions', 0, 'target'],
        code: 'invalid_type',
        expected: 'object',
        received: 'undefined',
        message: 'Required',
      },
    ]);
  });

  it('emits concise human output', () => {
    expect(formatValidationHuman(invalidPlanError())).toContain(
      'actions[0].target\n  Expected: object\n  Received: undefined',
    );
  });

  it('emits valid machine-readable JSON', () => {
    const output = JSON.parse(formatValidationJson(invalidPlanError()));
    expect(output.valid).toBe(false);
    expect(output.errors[0].path).toEqual(['actions', 0, 'target']);
  });
});
