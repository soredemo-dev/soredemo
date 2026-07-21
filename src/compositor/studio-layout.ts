import type { Rect } from './types.js';

export const STUDIO_BROWSER_CONTENT_RECT: Readonly<Rect> = {
  x: 240,
  y: 116,
  width: 1440,
  height: 900,
};

export const STUDIO_BROWSER_WINDOW_RECT: Readonly<Rect> = {
  x: 240,
  y: 64,
  width: 1440,
  height: 952,
};

export const STUDIO_LOCAL_WINDOW_RECT: Readonly<Rect> = {
  x: 0,
  y: 0,
  width: 1440,
  height: 952,
};

export const STUDIO_LOCAL_CONTENT_RECT: Readonly<Rect> = {
  x: 0,
  y: 52,
  width: 1440,
  height: 900,
};

export const STUDIO_TOOLBAR_HEIGHT = 52 as const;
export const STUDIO_WINDOW_RADIUS = 22 as const;

export const STUDIO_WINDOW_BORDER = {
  width: 1,
  color: 'rgba(15, 23, 42, 0.12)',
} as const;

export const STUDIO_WINDOW_SHADOW = {
  color: 'rgba(15, 23, 42, 0.30)',
  blur: 40,
  offsetX: 0,
  offsetY: 16,
} as const;

export const STUDIO_TOOLBAR = {
  background: '#F5F5F7',
  separator: 'rgba(15, 23, 42, 0.10)',
} as const;

export const STUDIO_TRAFFIC_LIGHTS = {
  centerY: 26,
  radius: 6,
  centersX: [22, 42, 62] as const,
  colors: ['#FF5F57', '#FEBC2E', '#28C840'] as const,
} as const;

export const STUDIO_GRADIENT = {
  start: { x: 0, y: 0 },
  end: { x: 1920, y: 1080 },
  stops: [
    { offset: 0, color: '#7C3AED' },
    { offset: 0.55, color: '#2563EB' },
    { offset: 1, color: '#0EA5E9' },
  ],
} as const;

export function validateStudioLayout(): void {
  const window = STUDIO_BROWSER_WINDOW_RECT;
  const content = STUDIO_BROWSER_CONTENT_RECT;
  if (
    window.x !== (1920 - window.width) / 2 ||
    window.y !== (1080 - window.height) / 2 ||
    content.x !== window.x ||
    content.y !== window.y + STUDIO_TOOLBAR_HEIGHT ||
    content.width !== window.width ||
    content.height + STUDIO_TOOLBAR_HEIGHT !== window.height
  ) {
    throw new Error('Studio window geometry is inconsistent');
  }
}
