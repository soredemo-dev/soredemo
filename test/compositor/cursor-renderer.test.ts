import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createCanvas } from '@napi-rs/canvas';
import { describe, expect, it } from 'vitest';
import { decodeCursorAsset, loadCursorAsset } from '../../src/compositor/cursor-asset.js';
import { cursorPlacement, drawCursor } from '../../src/compositor/cursor-renderer.js';

function pixel(data: Uint8Array, width: number, x: number, y: number): number[] {
  const offset = (y * width + x) * 4;
  return [...data.subarray(offset, offset + 4)];
}

async function markerAsset() {
  return decodeCursorAsset(
    Buffer.from(
      '<svg xmlns="http://www.w3.org/2000/svg" width="5" height="5"><rect x="1" y="2" width="3" height="3" fill="#ff00ff" shape-rendering="crispEdges"/></svg>',
    ),
    {
      sourceWidth: 5,
      sourceHeight: 5,
      hotspotX: 2,
      hotspotY: 3,
      renderedWidth: 5,
      renderedHeight: 5,
    },
  );
}

describe('cursor renderer', () => {
  it('places a non-zero marked hotspot at the requested output pixel', async () => {
    const canvas = createCanvas(20, 20);
    const context = canvas.getContext('2d');
    context.fillStyle = '#0044aa';
    context.fillRect(0, 0, 20, 20);
    const placement = drawCursor(context, await markerAsset(), { x: 10, y: 10 });
    expect(placement).toMatchObject({ drawX: 8, drawY: 7, width: 5, height: 5 });
    const bytes = canvas.data();
    expect(pixel(bytes, 20, 10, 10)).toEqual([255, 0, 255, 255]);
    expect(pixel(bytes, 20, 8, 7)).toEqual([0, 68, 170, 255]);
    expect(bytes.filter((_, index) => index % 4 === 3).every((alpha) => alpha === 255)).toBe(true);
  });

  it('preserves fractional placement geometry and fixed rendered size', async () => {
    const asset = await markerAsset();
    expect(cursorPlacement(asset, { x: 10.25, y: 11.75 })).toEqual({
      hotspotScreenX: 10.25,
      hotspotScreenY: 11.75,
      drawX: 8.25,
      drawY: 8.75,
      width: 5,
      height: 5,
    });
  });

  it('draws above browser pixels and clearing removes the stale prior cursor', async () => {
    const canvas = createCanvas(40, 40);
    const context = canvas.getContext('2d');
    const asset = await markerAsset();
    context.fillStyle = '#0044aa';
    context.fillRect(0, 0, 40, 40);
    drawCursor(context, asset, { x: 10, y: 10 });
    expect(pixel(canvas.data(), 40, 10, 10)).toEqual([255, 0, 255, 255]);
    context.fillStyle = '#0044aa';
    context.fillRect(0, 0, 40, 40);
    drawCursor(context, asset, { x: 30, y: 30 });
    expect(pixel(canvas.data(), 40, 10, 10)).toEqual([0, 68, 170, 255]);
    expect(pixel(canvas.data(), 40, 30, 30)).toEqual([255, 0, 255, 255]);
  });

  it('keeps production raster coverage inside its declared draw rectangle', async () => {
    const asset = await loadCursorAsset(resolve('assets/cursor.svg'));
    const canvas = createCanvas(100, 100);
    const context = canvas.getContext('2d');
    context.fillStyle = '#123456';
    context.fillRect(0, 0, 100, 100);
    const placement = drawCursor(context, asset, { x: 40, y: 40 });
    const bytes = canvas.data();
    let changed = 0;
    for (let y = 0; y < 100; y += 1) {
      for (let x = 0; x < 100; x += 1) {
        if (pixel(bytes, 100, x, y).join(',') === '18,52,86,255') continue;
        changed += 1;
        expect(x).toBeGreaterThanOrEqual(Math.floor(placement.drawX) - 1);
        expect(x).toBeLessThanOrEqual(Math.ceil(placement.drawX + placement.width));
        expect(y).toBeGreaterThanOrEqual(Math.floor(placement.drawY) - 1);
        expect(y).toBeLessThanOrEqual(Math.ceil(placement.drawY + placement.height));
      }
    }
    expect(changed).toBeGreaterThan(0);
  });

  it('keeps canvas.data as the compositor readback and never introduces getImageData', async () => {
    const sources = await Promise.all(
      ['base-frame-compositor.ts', 'cursor-frame-compositor.ts'].map((file) =>
        readFile(resolve('src/compositor', file), 'utf8'),
      ),
    );
    expect(sources.join('\n')).toContain('canvas.data()');
    expect(sources.join('\n')).not.toContain('getImageData');
  });
});
