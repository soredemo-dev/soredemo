import type { SKRSContext2D } from '@napi-rs/canvas';
import {
  STUDIO_LOCAL_WINDOW_RECT,
  STUDIO_TOOLBAR,
  STUDIO_TOOLBAR_HEIGHT,
  STUDIO_TRAFFIC_LIGHTS,
} from './studio-layout.js';

export function drawMacosToolbar(context: SKRSContext2D): void {
  context.fillStyle = STUDIO_TOOLBAR.background;
  context.fillRect(0, 0, STUDIO_LOCAL_WINDOW_RECT.width, STUDIO_TOOLBAR_HEIGHT);
  context.fillStyle = STUDIO_TOOLBAR.separator;
  context.fillRect(0, STUDIO_TOOLBAR_HEIGHT - 1, STUDIO_LOCAL_WINDOW_RECT.width, 1);
  for (const [index, centerX] of STUDIO_TRAFFIC_LIGHTS.centersX.entries()) {
    const color = STUDIO_TRAFFIC_LIGHTS.colors[index];
    if (!color) throw new Error('Traffic-light color is missing');
    context.beginPath();
    context.arc(
      centerX,
      STUDIO_TRAFFIC_LIGHTS.centerY,
      STUDIO_TRAFFIC_LIGHTS.radius,
      0,
      Math.PI * 2,
    );
    context.fillStyle = color;
    context.fill();
  }
}
