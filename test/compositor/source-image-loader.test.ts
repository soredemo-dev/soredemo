import { mkdir, mkdtemp, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { isAbsolute, join, resolve } from 'node:path';
import { createCanvas } from '@napi-rs/canvas';
import { describe, expect, it } from 'vitest';
import { SequentialSourceImageLoader } from '../../src/compositor/source-image-loader.js';
import { frameRecord } from './helpers.js';

async function fixture(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), 'soredemo-compositor-loader-'));
  await mkdir(resolve(directory, 'frames'));
  return directory;
}

function jpeg(width = 4, height = 2): Buffer {
  const canvas = createCanvas(width, height);
  const context = canvas.getContext('2d');
  context.fillStyle = '#35a7ff';
  context.fillRect(0, 0, width, height);
  return canvas.toBuffer('image/jpeg', 90);
}

describe('sequential source image loader', () => {
  it('decodes valid JPEGs and reuses only the consecutive current source', async () => {
    const directory = await fixture();
    await writeFile(resolve(directory, 'frames/000001.jpg'), jpeg());
    await writeFile(resolve(directory, 'frames/000002.jpg'), jpeg());
    const loader = await SequentialSourceImageLoader.create(directory, 4, 2);
    const first = await loader.load(frameRecord(0, 1));
    expect(await loader.load(frameRecord(1, 1))).toBe(first);
    expect(await loader.load(frameRecord(2, 2))).not.toBe(first);
    expect(loader.diagnostics()).toEqual({
      decodeCount: 2,
      cacheHits: 1,
      cacheMisses: 2,
      maxDecodedImagesRetained: 1,
      outOfOrderSourceSelections: 0,
    });
  });

  it('rejects missing, corrupt, absolute, and traversal paths', async () => {
    const directory = await fixture();
    await writeFile(resolve(directory, 'frames/corrupt.jpg'), 'not a JPEG');
    const loader = await SequentialSourceImageLoader.create(directory, 4, 2);
    await expect(
      loader.load({ ...frameRecord(0), sourceFile: 'frames/missing.jpg' }),
    ).rejects.toThrow('missing or unreadable');
    await expect(
      loader.load({ ...frameRecord(1), sourceFile: 'frames/corrupt.jpg' }),
    ).rejects.toThrow('Unable to decode');
    const absolute = resolve(directory, 'frames/corrupt.jpg');
    expect(isAbsolute(absolute)).toBe(true);
    await expect(loader.load({ ...frameRecord(2), sourceFile: absolute })).rejects.toThrow(
      'relative path',
    );
    await expect(loader.load({ ...frameRecord(3), sourceFile: '../outside.jpg' })).rejects.toThrow(
      'escapes',
    );
  });

  it('rejects symlinks and decoded dimension mismatches', async () => {
    const directory = await fixture();
    const realFile = resolve(directory, 'frames/real.jpg');
    await writeFile(realFile, jpeg());
    await symlink(realFile, resolve(directory, 'frames/link.jpg'));
    const loader = await SequentialSourceImageLoader.create(directory, 4, 2);
    await expect(loader.load({ ...frameRecord(0), sourceFile: 'frames/link.jpg' })).rejects.toThrow(
      'symbolic link',
    );

    await writeFile(resolve(directory, 'frames/wrong.jpg'), jpeg(3, 2));
    await expect(
      loader.load({ ...frameRecord(1), sourceFile: 'frames/wrong.jpg' }),
    ).rejects.toThrow('do not match');
  });

  it('fails on out-of-order source selections instead of growing a cache', async () => {
    const directory = await fixture();
    await writeFile(resolve(directory, 'frames/000001.jpg'), jpeg());
    await writeFile(resolve(directory, 'frames/000002.jpg'), jpeg());
    const loader = await SequentialSourceImageLoader.create(directory, 4, 2);
    await loader.load(frameRecord(0, 2));
    await expect(loader.load(frameRecord(1, 1))).rejects.toThrow('non-decreasing');
    expect(loader.diagnostics().outOfOrderSourceSelections).toBe(1);
    expect(loader.diagnostics().maxDecodedImagesRetained).toBe(1);
  });
});
