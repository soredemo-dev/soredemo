import type { Locator, Page } from 'playwright';
import { describe, expect, it } from 'vitest';
import {
  prepareTarget,
  type ResolvedLocator,
  resolveTarget,
} from '../../src/capture/target-resolver.js';

class FakeLocator {
  constructor(
    readonly matches: number,
    readonly visible = true,
    readonly enabled = true,
  ) {}

  count() {
    return Promise.resolve(this.matches);
  }
  nth() {
    return this;
  }
  evaluate() {
    return Promise.resolve({
      tagName: 'button',
      role: 'button',
      testId: 'candidate',
      ariaLabel: 'Candidate',
    });
  }
  isVisible() {
    return Promise.resolve(this.visible);
  }
  isEnabled() {
    return Promise.resolve(this.enabled);
  }
  boundingBox() {
    return Promise.resolve({ x: 10, y: 10, width: 100, height: 40 });
  }
  ariaSnapshot() {
    return Promise.resolve('- button "Candidate"');
  }
  scrollIntoViewIfNeeded() {
    return Promise.resolve();
  }
  waitFor() {
    return this.visible ? Promise.resolve() : Promise.reject(new Error('hidden'));
  }
}

function page(primary: FakeLocator, candidates = primary): Page {
  return {
    getByRole: () => primary,
    getByLabel: () => primary,
    getByTestId: () => primary,
    getByText: () => primary,
    locator: (selector: string) => (selector.includes(',') ? candidates : primary),
  } as unknown as Page;
}

describe('target resolver diagnostics', () => {
  it('returns bounded safe candidate summaries for missing targets', async () => {
    try {
      await resolveTarget(page(new FakeLocator(0), new FakeLocator(12)), {
        role: 'button',
        name: 'Create project',
      });
      throw new Error('expected failure');
    } catch (error) {
      expect(error).toMatchObject({
        code: 'TARGET_NOT_FOUND',
        targetDescription: 'role=button, name="Create project"',
        details: { matchCount: 0 },
      });
      expect((error as { details: { candidates: unknown[] } }).details.candidates).toHaveLength(10);
    }
  });

  it('never silently selects the first ambiguous target', async () => {
    try {
      await resolveTarget(page(new FakeLocator(3)), { testId: 'duplicate' });
      throw new Error('expected failure');
    } catch (error) {
      expect(error).toMatchObject({
        code: 'TARGET_AMBIGUOUS',
        details: { matchCount: 3 },
      });
      expect((error as { details: { candidates: unknown[] } }).details.candidates).toHaveLength(3);
    }
  });

  it('distinguishes invisible and disabled targets', async () => {
    const hidden = new FakeLocator(1, false, true);
    await expect(
      prepareTarget({
        strategy: 'testId',
        description: 'testId="hidden"',
        target: { strategy: 'testId', value: { testId: 'hidden' } },
        locator: hidden as unknown as Locator,
      }),
    ).rejects.toMatchObject({ code: 'TARGET_NOT_VISIBLE' });

    const disabled = new FakeLocator(1, true, false);
    await expect(
      prepareTarget(
        {
          strategy: 'testId',
          description: 'testId="disabled"',
          target: { strategy: 'testId', value: { testId: 'disabled' } },
          locator: disabled as unknown as Locator,
        } satisfies ResolvedLocator,
        { enabled: true },
      ),
    ).rejects.toMatchObject({ code: 'TARGET_NOT_ENABLED' });
  });
});
