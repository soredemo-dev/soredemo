import { describe, expect, it } from 'vitest';
import { assertCursorSynchronization } from '../../src/render/render-demo.js';

describe('cursor synchronization failure seam', () => {
  it('classifies incomplete or failing all-action audits', () => {
    expect(() =>
      assertCursorSynchronization(
        {
          statistics: {
            total: 3,
            byKind: { moveTo: 1, click: 2, type: 0 },
            errorDistanceOutputPx: { median: 0, p95: 4, max: 4 },
            insideTargetCount: 2,
            failures: 1,
          },
        },
        4,
      ),
    ).toThrowError(
      expect.objectContaining({
        code: 'CURSOR_SYNCHRONIZATION_FAILED',
        stage: 'composing',
      }),
    );
  });
});
