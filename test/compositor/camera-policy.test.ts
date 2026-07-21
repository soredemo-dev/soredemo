import { describe, expect, it } from 'vitest';
import {
  establishCamera,
  focusCamera,
  STUDIO_CAMERA_POLICY,
  transitionDurationMs,
} from '../../src/compositor/camera-policy.js';

const viewport = { width: 1440, height: 900 };

describe('studio camera policy', () => {
  it('starts established and deterministically focuses a target', () => {
    expect(establishCamera(viewport)).toEqual({ zoom: 1, centerCssX: 720, centerCssY: 450 });
    const target = { x: 200, y: 100, width: 100, height: 40 };
    expect(focusCamera(target, viewport)).toEqual(focusCamera(target, viewport));
    expect(focusCamera(target, viewport).zoom).toBeGreaterThanOrEqual(
      STUDIO_CAMERA_POLICY.defaultZoom,
    );
    expect(focusCamera(target, viewport).zoom).toBeLessThanOrEqual(STUDIO_CAMERA_POLICY.maxZoom);
  });

  it('preserves context and clamps edge targets', () => {
    const focused = focusCamera({ x: 0, y: 0, width: 20, height: 20 }, viewport);
    expect(focused.centerCssX).toBeCloseTo(viewport.width / focused.zoom / 2);
    expect(focused.centerCssY).toBeCloseTo(viewport.height / focused.zoom / 2);
  });

  it('clamps adaptive zoom and transition duration', () => {
    const broad = focusCamera({ x: 0, y: 0, width: 1200, height: 700 }, viewport);
    expect(broad.zoom).toBe(STUDIO_CAMERA_POLICY.defaultZoom);
    const duration = transitionDurationMs(
      establishCamera(viewport),
      focusCamera({ x: 1200, y: 800, width: 50, height: 30 }, viewport),
      viewport,
    );
    expect(duration).toBeGreaterThanOrEqual(STUDIO_CAMERA_POLICY.transitionMinMs);
    expect(duration).toBeLessThanOrEqual(STUDIO_CAMERA_POLICY.transitionMaxMs);
  });
});
