import { describe, expect, it } from 'vitest';
import { hitTestMatchesTarget } from '../../src/capture/click-recorder.js';
import { browserEpochToCaptureTimeMs } from '../../src/capture/page-instrumentation.js';

describe('page event contracts', () => {
  it('converts browser event epochs directly to capture-relative time', () => {
    expect(browserEpochToCaptureTimeMs(1_750_000_000_125, 1_750_000_000_000)).toBe(125);
  });

  it('accepts direct and descendant hit-test results', () => {
    expect(
      hitTestMatchesTarget({ hitFound: true, hitIsTarget: true, targetContainsHit: true }),
    ).toBe(true);
    expect(
      hitTestMatchesTarget({ hitFound: true, hitIsTarget: false, targetContainsHit: true }),
    ).toBe(true);
    expect(
      hitTestMatchesTarget({ hitFound: true, hitIsTarget: false, targetContainsHit: false }),
    ).toBe(false);
  });
});
