import { describe, expect, it } from 'vitest';
import {
  STUDIO_BROWSER_CONTENT_RECT,
  STUDIO_BROWSER_WINDOW_RECT,
  STUDIO_LOCAL_CONTENT_RECT,
  STUDIO_TOOLBAR_HEIGHT,
  STUDIO_WINDOW_RADIUS,
  validateStudioLayout,
} from '../../src/compositor/studio-layout.js';

describe('studio layout', () => {
  it('uses the fixed centered v0.1 geometry', () => {
    expect(() => validateStudioLayout()).not.toThrow();
    expect(STUDIO_BROWSER_WINDOW_RECT).toEqual({ x: 240, y: 64, width: 1440, height: 952 });
    expect(STUDIO_BROWSER_CONTENT_RECT).toEqual({ x: 240, y: 116, width: 1440, height: 900 });
    expect(STUDIO_LOCAL_CONTENT_RECT).toEqual({ x: 0, y: 52, width: 1440, height: 900 });
    expect(STUDIO_TOOLBAR_HEIGHT).toBe(52);
    expect(STUDIO_WINDOW_RADIUS).toBe(22);
    expect(STUDIO_BROWSER_WINDOW_RECT.x).toBe(
      1920 - STUDIO_BROWSER_WINDOW_RECT.x - STUDIO_BROWSER_WINDOW_RECT.width,
    );
    expect(STUDIO_BROWSER_WINDOW_RECT.y).toBe(
      1080 - STUDIO_BROWSER_WINDOW_RECT.y - STUDIO_BROWSER_WINDOW_RECT.height,
    );
  });
});
