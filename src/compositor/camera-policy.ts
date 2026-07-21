import type { BBox } from '../timeline/types.js';
import { clampCameraState } from './camera-projection.js';
import type { CameraState, Size } from './camera-types.js';

export interface StudioCameraPolicy {
  establishDurationMs: number;
  leadMs: number;
  settleBeforeClickMs: number;
  transitionMinMs: number;
  transitionMaxMs: number;
  defaultZoom: number;
  maxZoom: number;
  horizontalContextPaddingCssPx: number;
  verticalContextPaddingCssPx: number;
}

export const STUDIO_CAMERA_POLICY: Readonly<StudioCameraPolicy> = {
  establishDurationMs: 600,
  leadMs: 120,
  settleBeforeClickMs: 100,
  transitionMinMs: 350,
  transitionMaxMs: 700,
  defaultZoom: 1.25,
  maxZoom: 1.35,
  horizontalContextPaddingCssPx: 480,
  verticalContextPaddingCssPx: 320,
};

export function establishCamera(viewport: Size): CameraState {
  return { zoom: 1, centerCssX: viewport.width / 2, centerCssY: viewport.height / 2 };
}

export function focusCamera(
  target: BBox,
  viewport: Size,
  policy: StudioCameraPolicy = STUDIO_CAMERA_POLICY,
): CameraState {
  if (
    ![target.x, target.y, target.width, target.height].every(Number.isFinite) ||
    target.width <= 0 ||
    target.height <= 0
  ) {
    throw new Error('Camera focus target must be finite and positive');
  }
  const paddedWidth = target.width + policy.horizontalContextPaddingCssPx * 2;
  const paddedHeight = target.height + policy.verticalContextPaddingCssPx * 2;
  const containZoom = Math.min(viewport.width / paddedWidth, viewport.height / paddedHeight);
  const zoom = Math.min(policy.maxZoom, Math.max(policy.defaultZoom, containZoom));
  return clampCameraState(
    {
      zoom,
      centerCssX: target.x + target.width / 2,
      centerCssY: target.y + target.height / 2,
    },
    viewport,
  );
}

export function transitionDurationMs(
  from: CameraState,
  to: CameraState,
  viewport: Size,
  policy: StudioCameraPolicy = STUDIO_CAMERA_POLICY,
): number {
  const normalizedDistance = Math.hypot(
    (to.centerCssX - from.centerCssX) / viewport.width,
    (to.centerCssY - from.centerCssY) / viewport.height,
    to.zoom - from.zoom,
  );
  return Math.min(
    policy.transitionMaxMs,
    Math.max(policy.transitionMinMs, policy.transitionMinMs + normalizedDistance * 500),
  );
}
