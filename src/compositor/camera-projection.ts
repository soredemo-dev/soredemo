import type { Point } from '../timeline/types.js';
import type { CameraState, CssRect, Size, SourceCrop } from './camera-types.js';
import type { Rect } from './types.js';

const EPSILON = 1e-7;

function positiveSize(size: Size, name: string): void {
  if (
    !Number.isFinite(size.width) ||
    !Number.isFinite(size.height) ||
    size.width <= 0 ||
    size.height <= 0
  ) {
    throw new Error(`${name} dimensions must be finite and positive`);
  }
}

export function visibleCssRect(camera: CameraState, viewport: Size): CssRect {
  positiveSize(viewport, 'CSS viewport');
  if (!Number.isFinite(camera.zoom) || camera.zoom < 1) {
    throw new Error('Camera zoom must be finite and at least 1');
  }
  if (!Number.isFinite(camera.centerCssX) || !Number.isFinite(camera.centerCssY)) {
    throw new Error('Camera center must be finite');
  }
  const width = viewport.width / camera.zoom;
  const height = viewport.height / camera.zoom;
  const halfWidth = width / 2;
  const halfHeight = height / 2;
  const centerCssX = Math.min(viewport.width - halfWidth, Math.max(halfWidth, camera.centerCssX));
  const centerCssY = Math.min(
    viewport.height - halfHeight,
    Math.max(halfHeight, camera.centerCssY),
  );
  return { x: centerCssX - halfWidth, y: centerCssY - halfHeight, width, height };
}

export function clampCameraState(camera: CameraState, viewport: Size): CameraState {
  const visible = visibleCssRect(camera, viewport);
  return {
    zoom: camera.zoom,
    centerCssX: visible.x + visible.width / 2,
    centerCssY: visible.y + visible.height / 2,
  };
}

export function sourceCropForCamera(camera: CameraState, viewport: Size, source: Size): SourceCrop {
  positiveSize(source, 'Source image');
  const visible = visibleCssRect(camera, viewport);
  const scaleX = source.width / viewport.width;
  const scaleY = source.height / viewport.height;
  if (Math.abs(scaleX - scaleY) > EPSILON) {
    throw new Error('Source and CSS viewport scales must match');
  }
  const crop = {
    x: visible.x * scaleX,
    y: visible.y * scaleY,
    width: visible.width * scaleX,
    height: visible.height * scaleY,
  };
  validateSourceCrop(crop, source);
  return crop;
}

export function validateSourceCrop(crop: SourceCrop, source: Size): void {
  positiveSize(source, 'Source image');
  const values = [crop.x, crop.y, crop.width, crop.height];
  if (!values.every(Number.isFinite) || crop.width <= 0 || crop.height <= 0) {
    throw new Error('Source crop must be finite and positive');
  }
  if (
    crop.x < -EPSILON ||
    crop.y < -EPSILON ||
    crop.x + crop.width > source.width + EPSILON ||
    crop.y + crop.height > source.height + EPSILON
  ) {
    throw new Error('Camera source crop leaves captured pixels');
  }
}

export function projectCssPoint(
  point: Point,
  camera: CameraState,
  viewport: Size,
  contentRect: Rect,
): Point {
  if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) {
    throw new Error('CSS projection point must be finite');
  }
  positiveSize(contentRect, 'Content rectangle');
  const visible = visibleCssRect(camera, viewport);
  return {
    x: contentRect.x + ((point.x - visible.x) / visible.width) * contentRect.width,
    y: contentRect.y + ((point.y - visible.y) / visible.height) * contentRect.height,
  };
}

export function projectCssRect(
  rect: Rect,
  camera: CameraState,
  viewport: Size,
  contentRect: Rect,
): Rect {
  if (
    !Number.isFinite(rect.x) ||
    !Number.isFinite(rect.y) ||
    !Number.isFinite(rect.width) ||
    !Number.isFinite(rect.height) ||
    rect.width <= 0 ||
    rect.height <= 0
  ) {
    throw new Error('CSS projection rectangle must be finite and positive');
  }
  const topLeft = projectCssPoint(rect, camera, viewport, contentRect);
  const bottomRight = projectCssPoint(
    { x: rect.x + rect.width, y: rect.y + rect.height },
    camera,
    viewport,
    contentRect,
  );
  return {
    x: topLeft.x,
    y: topLeft.y,
    width: bottomRight.x - topLeft.x,
    height: bottomRight.y - topLeft.y,
  };
}

export function visibleFraction(rect: Rect, bounds: Rect): number {
  const left = Math.max(rect.x, bounds.x);
  const top = Math.max(rect.y, bounds.y);
  const right = Math.min(rect.x + rect.width, bounds.x + bounds.width);
  const bottom = Math.min(rect.y + rect.height, bounds.y + bounds.height);
  const area = Math.max(0, right - left) * Math.max(0, bottom - top);
  return area / (rect.width * rect.height);
}

export function pointInsideRect(point: Point, rect: Rect, tolerance = EPSILON): boolean {
  return (
    point.x >= rect.x - tolerance &&
    point.x <= rect.x + rect.width + tolerance &&
    point.y >= rect.y - tolerance &&
    point.y <= rect.y + rect.height + tolerance
  );
}
