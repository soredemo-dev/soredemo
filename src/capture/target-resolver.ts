import { setTimeout } from 'node:timers/promises';
import type { Locator, Page } from 'playwright';
import type { Target } from '../plan/normalized-plan.js';
import { RenderError } from '../render/errors.js';
import type { BBox, ResolvedTarget } from '../timeline/types.js';
import { isFinitePositiveBbox } from '../timeline/validation.js';

export interface ResolvedLocator {
  strategy: ResolvedTarget['strategy'];
  description: string;
  target: ResolvedTarget;
  locator: Locator;
}

export interface TargetCandidateSummary {
  tagName: string;
  role?: string;
  accessibleName?: string;
  testId?: string;
  visible: boolean;
  enabled: boolean;
  bbox: BBox | null;
}

export function describeTarget(target: Target): string {
  if ('role' in target)
    return `role=${target.role}${target.name ? `, name=${JSON.stringify(target.name)}` : ''}`;
  if ('label' in target) return `label=${JSON.stringify(target.label)}`;
  if ('testId' in target) return `testId=${JSON.stringify(target.testId)}`;
  if ('text' in target)
    return `text=${JSON.stringify(target.text)}${target.exact ? ', exact=true' : ''}`;
  return `css=${JSON.stringify(target.css)}`;
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
  if (count === 0) {
    const candidates = await summarizeCandidates(
      page.locator('button, input, textarea, select, a, [role], [data-testid]'),
    );
    throw new RenderError({
      code: 'TARGET_NOT_FOUND',
      stage: 'capturing',
      message: `Could not find ${description}`,
      targetDescription: description,
      details: { matchCount: 0, candidates },
    });
  }
  if (count !== 1) {
    throw new RenderError({
      code: 'TARGET_AMBIGUOUS',
      stage: 'capturing',
      message: `Matched ${count} elements for ${description}`,
      targetDescription: description,
      details: { matchCount: count, candidates: await summarizeCandidates(locator) },
    });
  }
  return { strategy, description, target: { strategy, value }, locator };
}

async function summarizeCandidates(locator: Locator): Promise<TargetCandidateSummary[]> {
  const count = Math.min(await locator.count(), 10);
  const candidates: TargetCandidateSummary[] = [];
  for (let index = 0; index < count; index += 1) {
    const candidate = locator.nth(index);
    const [attributes, visible, enabled, bbox, snapshot] = await Promise.all([
      candidate.evaluate((element) => ({
        tagName: element.tagName.toLowerCase(),
        role: element.getAttribute('role'),
        testId: element.getAttribute('data-testid'),
        ariaLabel: element.getAttribute('aria-label'),
      })),
      candidate.isVisible().catch(() => false),
      candidate.isEnabled().catch(() => false),
      candidate.boundingBox().catch(() => null),
      candidate.ariaSnapshot({ timeout: 1_000 }).catch(() => ''),
    ]);
    const snapshotName = snapshot.split('\n')[0]?.match(/^-[^"]*"([^"]*)"/)?.[1];
    const accessibleName = attributes.ariaLabel ?? snapshotName;
    candidates.push({
      tagName: attributes.tagName,
      ...(attributes.role ? { role: attributes.role } : {}),
      ...(accessibleName ? { accessibleName: accessibleName.slice(0, 160) } : {}),
      ...(attributes.testId ? { testId: attributes.testId } : {}),
      visible,
      enabled,
      bbox,
    });
  }
  return candidates;
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
  try {
    await resolved.locator.waitFor({ state: 'visible', timeout: 10_000 });
  } catch (error) {
    throw new RenderError({
      code: 'TARGET_NOT_VISIBLE',
      stage: 'capturing',
      message: `${resolved.description} is not visible`,
      targetDescription: resolved.description,
      cause: error,
    });
  }
  if (options.enabled && !(await resolved.locator.isEnabled())) {
    throw new RenderError({
      code: 'TARGET_NOT_ENABLED',
      stage: 'capturing',
      message: `${resolved.description} is disabled`,
      targetDescription: resolved.description,
    });
  }
  return stableTargetBbox(resolved.locator);
}
