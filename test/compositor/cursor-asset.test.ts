import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  decodeCursorAsset,
  loadCursorAsset,
  STUDIO_CURSOR,
} from '../../src/compositor/cursor-asset.js';

describe('cursor asset', () => {
  it('loads the bundled SVG with fixed intrinsic and rendered metadata', async () => {
    const file = resolve('assets/cursor.svg');
    const asset = await loadCursorAsset(file);
    expect([asset.image.width, asset.image.height]).toEqual([30, 38]);
    expect(asset.definition).toEqual(STUDIO_CURSOR);
    expect(asset.sha256).toMatch(/^[a-f0-9]{64}$/);
    const source = (await readFile(file, 'utf8')).replace('http://www.w3.org/2000/svg', '');
    expect(source).not.toMatch(/https?:\/\/|<image|<text|font-family/);
  });

  it('rejects intrinsic mismatches, invalid hotspots, and invalid rendered sizes', async () => {
    const svg = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="5" height="5"/>');
    await expect(
      decodeCursorAsset(svg, {
        sourceWidth: 6,
        sourceHeight: 5,
        hotspotX: 0,
        hotspotY: 0,
        renderedWidth: 6,
        renderedHeight: 5,
      }),
    ).rejects.toThrow('intrinsic dimensions');
    await expect(
      decodeCursorAsset(svg, {
        sourceWidth: 5,
        sourceHeight: 5,
        hotspotX: 5,
        hotspotY: 0,
        renderedWidth: 5,
        renderedHeight: 5,
      }),
    ).rejects.toThrow('inside source bounds');
    await expect(
      decodeCursorAsset(svg, {
        sourceWidth: 5,
        sourceHeight: 5,
        hotspotX: 0,
        hotspotY: 0,
        renderedWidth: 0,
        renderedHeight: 5,
      }),
    ).rejects.toThrow('positive and finite');
  });
});
