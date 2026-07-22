import { describe, expect, it } from 'vitest';
import {
  formatRuntimeVersionFailure,
  runtimeVersionFailure,
} from '../../src/cli/runtime-version.js';

describe('public-alpha Node runtime guard', () => {
  it.each([
    ['20.19.3', false],
    ['20.19.4', true],
    ['20.20.0', true],
    ['21.0.0', false],
    ['22.12.0', false],
    ['not-a-version', false],
  ])('checks %s', (version, supported) => {
    expect(runtimeVersionFailure(version) === null).toBe(supported);
  });

  it('has stable human and JSON diagnostics', () => {
    const failure = runtimeVersionFailure('22.1.0');
    expect(failure).not.toBeNull();
    if (!failure) return;
    expect(formatRuntimeVersionFailure(failure, false)).toContain(
      'within the Node 20 release line',
    );
    expect(JSON.parse(formatRuntimeVersionFailure(failure, true))).toEqual({
      success: false,
      code: 'UNSUPPORTED_NODE_VERSION',
      message:
        'Soredemo public alpha currently requires Node.js 20.19.4 or later within the Node 20 release line.',
      currentVersion: '22.1.0',
      requiredRange: '>=20.19.4 <21',
    });
  });
});
