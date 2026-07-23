import { access, mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { loadDemoPlan } from '../../src/plan/load.js';
import { applyProjectBootstrap, planProjectBootstrap } from '../../src/project/bootstrap.js';

describe('project bootstrap', () => {
  it('plans and atomically creates config, Demo Plan, and canonical Agent skill', async () => {
    const root = await mkdtemp(resolve(tmpdir(), 'soredemo-bootstrap-'));
    const plan = await planProjectBootstrap(root);
    expect(plan.files.map((file) => file.path)).toEqual([
      'soredemo.config.yaml',
      'demos/getting-started.yaml',
      '.agents/skills/soredemo/SKILL.md',
    ]);
    const created = await applyProjectBootstrap(plan);
    expect(created).toHaveLength(3);
    expect((await loadDemoPlan(resolve(root, 'demos/getting-started.yaml'))).actions).toHaveLength(
      2,
    );
    expect(await readFile(resolve(root, '.agents/skills/soredemo/SKILL.md'), 'utf8')).toContain(
      'exactly one element',
    );
  });

  it('reports conflicts and never overwrites', async () => {
    const root = await mkdtemp(resolve(tmpdir(), 'soredemo-bootstrap-conflict-'));
    await applyProjectBootstrap(await planProjectBootstrap(root));
    const second = await planProjectBootstrap(root);
    expect(second.files.every((file) => file.status === 'exists')).toBe(true);
    await expect(access(resolve(root, 'demos/getting-started.yaml'))).resolves.toBeUndefined();
  });
});
