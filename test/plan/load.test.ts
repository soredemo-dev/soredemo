import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  DemoPlanFileError,
  DemoPlanSyntaxError,
  DemoPlanValidationError,
} from '../../src/plan/errors.js';
import { loadDemoPlan } from '../../src/plan/load.js';

describe('loadDemoPlan', () => {
  it('loads and normalizes an explicit YAML path', async () => {
    const plan = await loadDemoPlan('examples/demo.yaml');

    expect(plan.name).toBe('create-project');
    expect(new Set(plan.actions.map((action) => action.action))).toEqual(
      new Set(['goto', 'wait', 'moveTo', 'click', 'type', 'scrollTo']),
    );
  });

  it('distinguishes schema validation errors', async () => {
    await expect(loadDemoPlan('test/fixtures/invalid-demo.yaml')).rejects.toBeInstanceOf(
      DemoPlanValidationError,
    );
  });

  it('distinguishes malformed YAML', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'soredemo-yaml-'));
    const path = join(directory, 'invalid.yaml');
    await writeFile(path, 'version: [\n');

    await expect(loadDemoPlan(path)).rejects.toBeInstanceOf(DemoPlanSyntaxError);
  });

  it('distinguishes unreadable paths', async () => {
    await expect(loadDemoPlan('test/fixtures/missing.yaml')).rejects.toBeInstanceOf(
      DemoPlanFileError,
    );
  });
});
