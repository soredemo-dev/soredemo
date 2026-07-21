import { performance } from 'node:perf_hooks';
import type { Page } from 'playwright';
import { describe, expect, it } from 'vitest';
import { type ActionExecutionContext, executeActions } from '../../src/capture/action-executor.js';
import type { RenderError } from '../../src/render/errors.js';

function context(page: Page, failures: RenderError[]): ActionExecutionContext {
  return {
    page,
    startupCalibration: {
      browserEpochAtDriverZeroMs: 1_000,
      roundTripMs: 0,
      sampledAtDriverMs: performance.now(),
    },
    captureOriginEpochMs: 1_000,
    cursor: { x: 0, y: 0 },
    cssViewport: { width: 1440, height: 900 },
    signal: new AbortController().signal,
    pace: 'balanced',
    onActionFailure: (error) => {
      failures.push(error);
    },
  };
}

describe('action failure classification', () => {
  it('rejects unsupported goto schemes before navigation', async () => {
    const failures: RenderError[] = [];
    await expect(
      executeActions(context({} as Page, failures), [
        { action: 'goto', url: 'file:///private/demo.html' },
      ]),
    ).rejects.toMatchObject({
      code: 'NAVIGATION_FAILED',
      actionIndex: 0,
      actionKind: 'goto',
    });
    expect(failures).toHaveLength(1);
  });

  it('classifies visible-condition timeouts with target metadata', async () => {
    const failures: RenderError[] = [];
    const locator = {
      count: () => Promise.resolve(1),
      waitFor: () => Promise.reject(new Error('timed out')),
    };
    const page = { getByTestId: () => locator } as unknown as Page;
    await expect(
      executeActions(context(page, failures), [
        {
          action: 'wait',
          until: { visible: { testId: 'never-visible' } },
          timeoutMs: 25,
          settleMs: 0,
        },
      ]),
    ).rejects.toMatchObject({
      code: 'ACTION_TIMEOUT',
      actionIndex: 0,
      actionKind: 'wait',
      targetDescription: 'testId="never-visible"',
    });
    expect(failures).toHaveLength(1);
  });
});
