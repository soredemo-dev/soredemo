import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createCanvas } from '@napi-rs/canvas';
import { describe, expect, it } from 'vitest';
import { drawStudioGradient } from '../../src/compositor/gradient-background.js';
import { drawMacosToolbar } from '../../src/compositor/macos-toolbar.js';
import { addRoundedRectPath } from '../../src/compositor/rounded-rect.js';
import {
  STUDIO_GRADIENT,
  STUDIO_TOOLBAR,
  STUDIO_TRAFFIC_LIGHTS,
} from '../../src/compositor/studio-layout.js';
import {
  createStudioWindowShadowLayer,
  drawStudioWindowBorder,
  drawStudioWindowShadow,
  STUDIO_SHADOW_LAYER_RECT,
} from '../../src/compositor/window-shadow.js';

function pixel(data: Uint8Array, width: number, x: number, y: number): number[] {
  const offset = (y * width + x) * 4;
  return [...data.subarray(offset, offset + 4)];
}

describe('studio drawing primitives', () => {
  it('draws the exact opaque deterministic gradient', () => {
    const first = createCanvas(1920, 1080);
    const second = createCanvas(1920, 1080);
    drawStudioGradient(first.getContext('2d'));
    drawStudioGradient(second.getContext('2d'));
    expect(STUDIO_GRADIENT.stops).toEqual([
      { offset: 0, color: '#7C3AED' },
      { offset: 0.55, color: '#2563EB' },
      { offset: 1, color: '#0EA5E9' },
    ]);
    const firstData = first.data();
    const secondData = second.data();
    expect(createHash('sha256').update(firstData).digest('hex')).toBe(
      createHash('sha256').update(secondData).digest('hex'),
    );
    for (const [x, y] of [
      [0, 0],
      [1919, 0],
      [0, 1079],
      [1919, 1079],
    ]) {
      expect(pixel(firstData, 1920, x ?? 0, y ?? 0)[3]).toBe(255);
      expect(pixel(firstData, 1920, x ?? 0, y ?? 0).slice(0, 3)).not.toEqual([0, 0, 0]);
    }
  });

  it('clips a manual rounded path and rejects invalid radius', () => {
    const canvas = createCanvas(40, 40);
    const context = canvas.getContext('2d');
    context.fillStyle = '#0000ff';
    context.fillRect(0, 0, 40, 40);
    context.save();
    addRoundedRectPath(context, { x: 5, y: 5, width: 30, height: 30 }, 10);
    context.clip();
    context.fillStyle = '#ff0000';
    context.fillRect(5, 5, 30, 30);
    context.restore();
    expect(pixel(canvas.data(), 40, 5, 5)).toEqual([0, 0, 255, 255]);
    expect(pixel(canvas.data(), 40, 15, 5)[0]).toBeGreaterThan(200);
    expect(pixel(canvas.data(), 40, 20, 20)).toEqual([255, 0, 0, 255]);
    expect(() => addRoundedRectPath(context, { x: 0, y: 0, width: 10, height: 10 }, 6)).toThrow(
      /invalid/,
    );
  });

  it('draws deterministic toolbar, separator, and traffic lights without fonts', async () => {
    const canvas = createCanvas(1440, 952);
    drawMacosToolbar(canvas.getContext('2d'));
    const data = canvas.data();
    expect(pixel(data, 1440, 100, 10)).toEqual([245, 245, 247, 255]);
    for (const [index, x] of STUDIO_TRAFFIC_LIGHTS.centersX.entries()) {
      expect(pixel(data, 1440, x, STUDIO_TRAFFIC_LIGHTS.centerY)[3]).toBe(255);
      expect(pixel(data, 1440, x, STUDIO_TRAFFIC_LIGHTS.centerY).slice(0, 3)).not.toEqual([
        245, 245, 247,
      ]);
      expect(STUDIO_TRAFFIC_LIGHTS.colors[index]).toBeDefined();
    }
    expect(pixel(data, 1440, 100, 51)).not.toEqual(pixel(data, 1440, 100, 50));
    expect(STUDIO_TOOLBAR.background).toBe('#F5F5F7');
    const source = await readFile('src/compositor/macos-toolbar.ts', 'utf8');
    expect(source).not.toMatch(/font|fillText|strokeText/);
  });

  it('restores shadow state and renders deterministic shadow and border', () => {
    const canvas = createCanvas(1920, 1080);
    const context = canvas.getContext('2d');
    drawStudioGradient(context);
    context.shadowColor = 'rgba(1, 2, 3, 0.4)';
    context.shadowBlur = 3;
    context.shadowOffsetX = 4;
    context.shadowOffsetY = 5;
    drawStudioWindowShadow(context);
    expect(context.shadowColor).toBe('rgba(1, 2, 3, 0.4)');
    expect(context.shadowBlur).toBe(3);
    expect(context.shadowOffsetX).toBe(4);
    expect(context.shadowOffsetY).toBe(5);
    const beforeBorder = Buffer.from(canvas.data());
    drawStudioWindowBorder(context);
    expect(Buffer.from(canvas.data())).not.toEqual(beforeBorder);
    const firstLayer = createStudioWindowShadowLayer();
    const secondLayer = createStudioWindowShadowLayer();
    expect({ width: firstLayer.width, height: firstLayer.height }).toEqual({
      width: STUDIO_SHADOW_LAYER_RECT.width,
      height: STUDIO_SHADOW_LAYER_RECT.height,
    });
    expect(createHash('sha256').update(firstLayer.data()).digest('hex')).toBe(
      createHash('sha256').update(secondLayer.data()).digest('hex'),
    );
  });
});
