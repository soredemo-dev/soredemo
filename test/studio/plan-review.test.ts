import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  PlanApproval,
  planSha256,
  saveApprovedPlan,
  validateProposal,
} from '../../src/studio/plan-review.js';

const proposal = {
  schemaVersion: 1 as const,
  title: 'Create a project',
  summary: 'A small flow',
  assumptions: [],
  plan: {
    version: 1 as const,
    name: 'create-project',
    url: 'http://127.0.0.1:3000',
    intent: { goal: 'Create a project' },
    actions: [
      { action: 'type' as const, target: { label: 'Project name' }, text: 'Private value' },
    ],
  },
  unresolved: [],
  warnings: [],
};

describe('Studio plan review', () => {
  it('invalidates approval whenever the exact plan changes', () => {
    const approval = new PlanApproval();
    const hash = approval.approve(proposal.plan);
    expect(hash).toBe(planSha256(proposal.plan));
    expect(approval.isApproved(proposal.plan)).toBe(true);
    expect(approval.isApproved({ ...proposal.plan, name: 'changed' })).toBe(false);
  });

  it('validates and atomically saves only an approved project-relative plan', async () => {
    const root = await mkdtemp(resolve(tmpdir(), 'soredemo-plan-review-'));
    const validated = validateProposal(proposal);
    const saved = await saveApprovedPlan({
      projectRoot: root,
      relativePath: 'demos/create-project.yaml',
      proposal: validated,
      approvedHash: planSha256(validated.plan),
    });
    expect(await readFile(saved.path, 'utf8')).toContain('Project name');
    await expect(
      saveApprovedPlan({
        projectRoot: root,
        relativePath: '../escape.yaml',
        proposal: validated,
        approvedHash: planSha256(validated.plan),
      }),
    ).rejects.toThrow('STUDIO_PATH_INVALID');
    await expect(
      saveApprovedPlan({
        projectRoot: root,
        relativePath: 'demos/create-project.yaml',
        proposal: validated,
        approvedHash: planSha256(validated.plan),
      }),
    ).rejects.toThrow('Refusing to overwrite');
  });

  it('rejects unsupported Agent actions', () => {
    expect(() =>
      validateProposal({
        ...proposal,
        plan: { ...proposal.plan, actions: [{ action: 'hover', target: { testId: 'x' } }] },
      }),
    ).toThrow();
  });
});
