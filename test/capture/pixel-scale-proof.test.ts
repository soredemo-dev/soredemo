import { describe, expect, it } from 'vitest';
import { assertCapturePixelScaleProof } from '../../src/capture/pixel-scale-proof.js';
import type { CapturePixelScaleProof } from '../../src/capture/types.js';

function proof(passed: boolean): CapturePixelScaleProof {
  return {
    method: 'cdp-screencast-css-color-bands',
    passed,
    probeCssSize: { width: 32, height: 32 },
    expectedPaintedScale: 2,
    jpegDimensions: { width: 2880, height: 1800 },
    samples: [
      {
        x: 8,
        y: 32,
        expected: [255, 0, 0],
        observed: passed ? [255, 0, 0] : [0, 255, 0],
        distance: passed ? 0 : 360,
      },
    ],
    cdpLayoutMetrics: {
      layoutViewport: { pageX: 0, pageY: 0, clientWidth: 1440, clientHeight: 900 },
    },
  };
}

describe('capture painted pixel scale', () => {
  it('accepts a genuine device-scale proof', () => {
    expect(() => assertCapturePixelScaleProof(proof(true))).not.toThrow();
  });

  it('rejects a dimension-correct quadrant-painted frame', () => {
    try {
      assertCapturePixelScaleProof(proof(false));
      throw new Error('expected failure');
    } catch (error) {
      expect(error).toMatchObject({
        code: 'CAPTURE_PIXEL_SCALE_INVALID',
        stage: 'preparing-page',
      });
    }
  });
});
