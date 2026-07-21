import type { SKRSContext2D } from '@napi-rs/canvas';
import { projectCssPoint } from './camera-projection.js';
import type { CameraState, Size } from './camera-types.js';
import { CLICK_RIPPLE_STYLE, type ClickRippleFrameState } from './click-feedback-track.js';
import type { Rect } from './types.js';

export interface RenderedClickRipple extends ClickRippleFrameState {
  screenX: number;
  screenY: number;
}

export function drawClickFeedback(
  context: SKRSContext2D,
  ripples: readonly ClickRippleFrameState[],
  camera: CameraState,
  viewport: Size,
  contentRect: Rect,
): RenderedClickRipple[] {
  const rendered: RenderedClickRipple[] = [];
  context.save();
  context.lineWidth = CLICK_RIPPLE_STYLE.strokeWidth;
  for (const ripple of ripples) {
    const center = projectCssPoint(ripple.clickPoint, camera, viewport, contentRect);
    context.beginPath();
    context.arc(center.x, center.y, ripple.radius, 0, Math.PI * 2);
    context.strokeStyle = `rgba(255, 255, 255, ${ripple.opacity})`;
    context.stroke();
    rendered.push({ ...ripple, screenX: center.x, screenY: center.y });
  }
  context.restore();
  return rendered;
}
