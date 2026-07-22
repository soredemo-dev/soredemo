import { readFile } from 'node:fs/promises';
import { describe, expect, it } from 'vitest';
import { loadDemoPlan } from '../../src/plan/load.js';

describe('public alpha launch showcase', () => {
  it('uses public-safe synthetic content and every supported action kind', async () => {
    const plan = await loadDemoPlan('examples/launch-showcase/demo.yaml');
    expect(new Set(plan.actions.map((action) => action.action))).toEqual(
      new Set(['goto', 'wait', 'moveTo', 'click', 'type', 'scrollTo']),
    );
    expect(plan.actions.filter((action) => action.action === 'moveTo')).toHaveLength(1);
    expect(plan.actions.filter((action) => action.action === 'click')).toHaveLength(2);
    expect(plan.actions.filter((action) => action.action === 'type')).toHaveLength(1);

    const html = await readFile('examples/launch-showcase/index.html', 'utf8');
    expect(html).toContain('data-testid="demo-ready"');
    expect(html).toContain('data-capture-probe');
    expect(html).not.toMatch(/fixture|diagnostic|customer|password/iu);
  });
});
