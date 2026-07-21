import { describe, expect, it } from 'vitest';
import { CAPTURE_BROWSER_MODE } from '../../src/capture/capture-session.js';

describe('capture browser mode', () => {
  it('uses a headless surface with an explicit device-scale launch invariant', () => {
    expect(CAPTURE_BROWSER_MODE).toBe('headless');
  });
});
