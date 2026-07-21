import { describe, expect, it } from 'vitest';
import { validateCdpFrameTimestamp } from '../../src/capture/cdp-screencast.js';

describe('CDP timestamp failure seam', () => {
  it('fails backward timestamps with complete bounded diagnostics', () => {
    try {
      validateCdpFrameTimestamp({
        previousFrameIndex: 41,
        currentFrameIndex: 42,
        previousFrameEpochMs: 1_000,
        currentFrameEpochMs: 997.542,
        previousReceivedDriverMs: 500,
        currentReceivedDriverMs: 510,
        startupCalibration: {
          browserEpochAtDriverZeroMs: 500,
          roundTripMs: 0.4,
          sampledAtDriverMs: 1,
        },
        queue: {
          received: 42,
          acknowledged: 41,
          written: 41,
          highWaterMark: 1,
          overflowCount: 0,
          writeFailures: 0,
        },
        environment: {
          playwrightVersion: '1.61.1',
          chromiumVersion: '149.0.7827.55',
          chromiumLaunchArguments: ['--force-device-scale-factor=2'],
        },
      });
      throw new Error('expected failure');
    } catch (error) {
      expect(error).toMatchObject({
        code: 'CAPTURE_TIMESTAMP_INVALID',
        stage: 'capturing',
        details: {
          previousFrameIndex: 41,
          currentFrameIndex: 42,
          signedDeltaMs: -2.45799999999997,
          endingCalibration: null,
        },
      });
    }
  });
});
