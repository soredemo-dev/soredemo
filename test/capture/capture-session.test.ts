import { describe, expect, it } from 'vitest';
import { CAPTURE_BROWSER_MODE } from '../../src/capture/capture-session.js';

describe('capture browser mode', () => {
  it('uses headed Chromium to preserve genuine device-scale-factor pixels', () => {
    expect(CAPTURE_BROWSER_MODE).toBe('headed');
  });
});
