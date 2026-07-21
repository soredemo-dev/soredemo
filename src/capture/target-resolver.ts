import { setTimeout } from 'node:timers/promises';
import type { Locator, Page } from 'playwright';
import type { Target } from '../plan/normalized-plan.js';
import type { BBox, ResolvedTarget } from '../timeline/types.js';
import { isFinitePositiveBbox } from '../timeline/validation.js';

export interface ResolvedLocator {
  strategy: ResolvedTarget['strategy'];
  description: string;
  target: ResolvedTarget;
  locator: Locator;
}

export function describeTarget(target: Target): string {
  if ('role' in target)
    return `role ${JSON.stringify(target.role)}${target.name ? ` named ${JSON.stringify(target.name)}` : ''}`;
  if ('label' in target) return `label ${JSON.stringify(target.label)}`;
  if ('testId' in target) return `test ID ${JSON.stringify(target.testId)}`;
  if ('text' in target)
    return `text ${JSON.stringify(target.text)}${target.exact ? ' (exact)' : ''}`;
  return `CSS selector ${JSON.stringify(target.css)}`;
}

export async function resolveTarget(page: Page, target: Target): Promise<ResolvedLocator> {
  let strategy: ResolvedTarget['strategy'];
  let value: ResolvedTarget['value'];
  let locator: Locator;
  if ('role' in target) {
    strategy = 'role';
    value = { role: target.role, name: target.name };
    locator = page.getByRole(
      target.role as Parameters<Page['getByRole']>[0],
      target.name ? { name: target.name } : {},
    );
  } else if ('label' in target) {
    strategy = 'label';
    value = { label: target.label };
    locator = page.getByLabel(target.label);
  } else if ('testId' in target) {
    strategy = 'testId';
    value = { testId: target.testId };
    locator = page.getByTestId(target.testId);
  } else if ('text' in target) {
    strategy = 'text';
    value = { text: target.text, exact: target.exact };
    locator = page.getByText(target.text, { exact: target.exact });
  } else {
    strategy = 'css';
    value = { css: target.css };
    locator = page.locator(target.css);
  }
  const description = describeTarget(target);
  const count = await locator.count();
  if (count === 0) throw new Error(`TARGET_NOT_FOUND: No element matches ${description}`);
  if (count !== 1) throw new Error(`TARGET_AMBIGUOUS: ${count} elements match ${description}`);
  return { strategy, description, target: { strategy, value }, locator };
}

export async function stableTargetBbox(locator: Locator, tolerancePx = 0.25): Promise<BBox> {
  for (let attempt = 0; attempt < 12; attempt += 1) {
    const samples = await locator.evaluate(async (element) => {
      const values: BBox[] = [];
      for (let index = 0; index < 4; index += 1) {
        await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
        const rect = element.getBoundingClientRect();
        values.push({ x: rect.x, y: rect.y, width: rect.width, height: rect.height });
      }
      return values;
    });
    const stable = samples.slice(1).every((sample, index) => {
      const previous = samples[index];
      return (
        previous !== undefined &&
        Math.max(
          Math.abs(previous.x - sample.x),
          Math.abs(previous.y - sample.y),
          Math.abs(previous.width - sample.width),
          Math.abs(previous.height - sample.height),
        ) <= tolerancePx
      );
    });
    const final = samples.at(-1);
    if (stable && final && isFinitePositiveBbox(final)) return final;
    await setTimeout(25);
  }
  throw new Error('Target geometry did not stabilize');
}

export async function prepareTarget(
  resolved: ResolvedLocator,
  options: { enabled?: boolean } = {},
): Promise<BBox> {
  await resolved.locator.scrollIntoViewIfNeeded();
  await resolved.locator.waitFor({ state: 'visible', timeout: 10_000 });
  if (options.enabled && !(await resolved.locator.isEnabled()))
    throw new Error(`${resolved.description} is disabled`);
  return stableTargetBbox(resolved.locator);
}
