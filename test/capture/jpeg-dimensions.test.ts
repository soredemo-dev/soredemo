import { describe, expect, it } from 'vitest';
import { readJpegDimensions } from '../../src/capture/jpeg-dimensions.js';
import { syntheticJpeg } from './jpeg-fixture.js';

describe('readJpegDimensions', () => {
  it('reads dimensions from a start-of-frame segment', () => {
    expect(readJpegDimensions(syntheticJpeg(2880, 1800))).toEqual({
      width: 2880,
      height: 1800,
    });
  });

  it('rejects non-JPEG data', () => {
    expect(() => readJpegDimensions(Buffer.from('not a jpeg'))).toThrow(
      'Invalid JPEG start-of-image marker',
    );
  });
});
