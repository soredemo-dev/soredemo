import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { type Image, loadImage } from '@napi-rs/canvas';

export interface CursorAssetDefinition {
  sourceWidth: number;
  sourceHeight: number;
  hotspotX: number;
  hotspotY: number;
  renderedWidth: number;
  renderedHeight: number;
}

export interface LoadedCursorAsset {
  image: Image;
  definition: CursorAssetDefinition;
  sha256: string;
}

export const STUDIO_CURSOR: CursorAssetDefinition = {
  sourceWidth: 30,
  sourceHeight: 38,
  hotspotX: 2,
  hotspotY: 2,
  renderedWidth: 30,
  renderedHeight: 38,
};

function positiveFinite(value: number, field: string): void {
  if (!Number.isFinite(value) || value <= 0)
    throw new Error(`${field} must be positive and finite`);
}

export async function decodeCursorAsset(
  source: Buffer | Uint8Array,
  definition: CursorAssetDefinition,
): Promise<LoadedCursorAsset> {
  positiveFinite(definition.sourceWidth, 'Cursor source width');
  positiveFinite(definition.sourceHeight, 'Cursor source height');
  positiveFinite(definition.renderedWidth, 'Cursor rendered width');
  positiveFinite(definition.renderedHeight, 'Cursor rendered height');
  if (
    !Number.isFinite(definition.hotspotX) ||
    !Number.isFinite(definition.hotspotY) ||
    definition.hotspotX < 0 ||
    definition.hotspotY < 0 ||
    definition.hotspotX >= definition.sourceWidth ||
    definition.hotspotY >= definition.sourceHeight
  ) {
    throw new Error('Cursor hotspot must be inside source bounds');
  }
  let image: Image;
  try {
    image = await loadImage(source);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Unable to decode cursor asset: ${message}`);
  }
  if (image.width !== definition.sourceWidth || image.height !== definition.sourceHeight) {
    throw new Error(
      `Cursor intrinsic dimensions ${image.width}x${image.height} do not match ${definition.sourceWidth}x${definition.sourceHeight}`,
    );
  }
  return {
    image,
    definition: { ...definition },
    sha256: createHash('sha256').update(source).digest('hex'),
  };
}

export async function loadCursorAsset(
  file: string,
  definition: CursorAssetDefinition = STUDIO_CURSOR,
): Promise<LoadedCursorAsset> {
  return decodeCursorAsset(await readFile(file), definition);
}
