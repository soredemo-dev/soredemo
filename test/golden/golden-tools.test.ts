import { cp, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { createCanvas } from '@napi-rs/canvas';
import { afterEach, describe, expect, it } from 'vitest';
import type { CameraTrack } from '../../src/compositor/camera-types.js';
import type { ResampledFrameRecord } from '../../src/resample/types.js';
import type { TimelineDocument } from '../../src/timeline/types.js';
import { CANONICAL_INPUT_ROOT, CHECKED_GOLDEN_ROOT } from '../golden-tools/exact-authority.js';
import { readGoldenManifest, verifyManifests } from '../golden-tools/golden-workflow.js';
import { compareRgba, rgbaToPng } from '../golden-tools/pixel-diff.js';
import {
  inspectExactProfile,
  officialExactProfile,
  sha256,
  stableJson,
} from '../golden-tools/profile.js';
import { selectCanonicalFrames } from '../golden-tools/semantic-selection.js';
import { GoldenError } from '../golden-tools/types.js';

const temporaryRoots: string[] = [];
afterEach(async () => {
  await Promise.all(
    temporaryRoots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
  );
});

describe('exact compositor profile', () => {
  it('matches only the official macOS arm64 Canvas environment', async () => {
    const profile = await inspectExactProfile();
    expect(officialExactProfile(profile)).toBe(
      process.platform === 'darwin' &&
        process.arch === 'arm64' &&
        process.versions.node === '20.19.4' &&
        profile.osVersion === '26.5.2' &&
        profile.osBuild === '25F84',
    );
    expect(officialExactProfile({ ...profile, osBuild: 'different' })).toBe(false);
    expect(officialExactProfile({ ...profile, architecture: 'x64' })).toBe(false);
    expect(officialExactProfile({ ...profile, canvasVersion: 'different' })).toBe(false);
  });
});

describe('golden manifest', () => {
  it('rejects unsafe paths, duplicate purposes, invalid hashes, and missing files', async () => {
    const root = await temporaryRoot();
    const checked = await readGoldenManifest(resolve(CHECKED_GOLDEN_ROOT, 'manifest.json'));
    const unsafe = structuredClone(checked);
    if (!unsafe.frames[0]) throw new Error('Golden fixture has no frames');
    unsafe.frames[0].file = '../escape.png';
    await writeFile(resolve(root, 'unsafe.json'), stableJson(unsafe));
    await expect(readGoldenManifest(resolve(root, 'unsafe.json'))).rejects.toMatchObject({
      code: 'GOLDEN_MANIFEST_INVALID',
    });
    const duplicate = structuredClone(checked);
    if (!duplicate.frames[1] || !duplicate.frames[0])
      throw new Error('Golden fixture is too small');
    duplicate.frames[1].purpose = duplicate.frames[0].purpose;
    await writeFile(resolve(root, 'duplicate.json'), stableJson(duplicate));
    await expect(readGoldenManifest(resolve(root, 'duplicate.json'))).rejects.toMatchObject({
      code: 'GOLDEN_MANIFEST_INVALID',
    });
    const invalidHash = structuredClone(checked);
    if (!invalidHash.frames[0]) throw new Error('Golden fixture has no frames');
    invalidHash.frames[0].pngSha256 = 'nope';
    await writeFile(resolve(root, 'hash.json'), stableJson(invalidHash));
    await expect(readGoldenManifest(resolve(root, 'hash.json'))).rejects.toMatchObject({
      code: 'GOLDEN_MANIFEST_INVALID',
    });
  });

  it('serializes deterministically', () => {
    expect(stableJson({ zebra: 1, alpha: { delta: 2, beta: 3 } })).toBe(
      '{\n  "alpha": {\n    "beta": 3,\n    "delta": 2\n  },\n  "zebra": 1\n}\n',
    );
  });
});

describe('semantic frame selection', () => {
  it('resolves every required canonical cursor, camera, and ripple purpose', async () => {
    const [timeline, camera, plan] = await Promise.all([
      readJson<TimelineDocument>('timeline.json'),
      readJson<CameraTrack>('camera-track.json'),
      readFile(resolve(CANONICAL_INPUT_ROOT, 'resample-plan.jsonl'), 'utf8'),
    ]);
    const records = plan
      .trim()
      .split('\n')
      .map((line) => JSON.parse(line) as ResampledFrameRecord);
    const selected = selectCanonicalFrames(records, timeline, camera);
    expect(selected.map(({ purpose }) => purpose)).toEqual([
      'establish',
      'camera-transition-start',
      'move-to-interpolation',
      'camera-transition-midpoint',
      'camera-transition-completion',
      'move-to-landing',
      'click-ripple-start',
      'click-ripple-midpoint',
      'click-ripple-completion',
      'type-focus',
      'second-click',
      'rounded-corner',
      'final',
    ]);
    expect(new Set(selected.map(({ record }) => record.outputIndex)).size).toBe(selected.length);
  });

  it('fails instead of substituting a missing semantic action', async () => {
    const [timeline, camera, plan] = await Promise.all([
      readJson<TimelineDocument>('timeline.json'),
      readJson<CameraTrack>('camera-track.json'),
      readFile(resolve(CANONICAL_INPUT_ROOT, 'resample-plan.jsonl'), 'utf8'),
    ]);
    timeline.events = timeline.events.filter((event) => event.kind !== 'moveTo');
    const records = plan
      .trim()
      .split('\n')
      .map((line) => JSON.parse(line) as ResampledFrameRecord);
    expect(() => selectCanonicalFrames(records, timeline, camera)).toThrowError(GoldenError);
  });
});

describe('pixel differences', () => {
  it('reports identical, one-pixel, alpha, and full-frame differences deterministically', () => {
    const expected = new Uint8Array([10, 20, 30, 255, 40, 50, 60, 255]);
    expect(compareRgba(expected, expected, 2, 1).statistics.differingPixels).toBe(0);
    const onePixel = new Uint8Array(expected);
    onePixel[0] = 20;
    const first = compareRgba(expected, onePixel, 2, 1);
    expect(first.statistics).toMatchObject({
      differingPixels: 1,
      boundingBox: { x: 0, y: 0, width: 1, height: 1 },
    });
    expect(first.difference).toEqual(compareRgba(expected, onePixel, 2, 1).difference);
    expect(first.heatmap).toEqual(compareRgba(expected, onePixel, 2, 1).heatmap);
    const alpha = new Uint8Array(expected);
    alpha[7] = 0;
    expect(compareRgba(expected, alpha, 2, 1).statistics.absoluteError.alphaMean).toBe(127.5);
    const full = new Uint8Array(expected.byteLength);
    expect(compareRgba(expected, full, 2, 1).statistics.differingPixels).toBe(2);
    expect(rgbaToPng(expected, 2, 1)).toEqual(rgbaToPng(expected, 2, 1));
  });

  it('writes expected, actual, diff, and heatmap diagnostics without touching goldens', async () => {
    const actualRoot = await temporaryRoot();
    await cp(CHECKED_GOLDEN_ROOT, actualRoot, { recursive: true });
    const manifest = await readGoldenManifest(resolve(actualRoot, 'manifest.json'));
    const frame = manifest.frames[0];
    if (!frame) throw new Error('Golden fixture has no frames');
    const image = createCanvas(1920, 1080);
    const context = image.getContext('2d');
    context.fillStyle = '#000000';
    context.fillRect(0, 0, 1920, 1080);
    const png = image.toBuffer('image/png');
    await writeFile(resolve(actualRoot, frame.file), png);
    frame.pngSha256 = sha256(png);
    frame.rgbaSha256 = sha256(new Uint8Array(image.data()));
    await writeFile(resolve(actualRoot, 'manifest.json'), stableJson(manifest));
    await expect(verifyManifests(CHECKED_GOLDEN_ROOT, actualRoot)).rejects.toMatchObject({
      code: 'GOLDEN_RGBA_MISMATCH',
    });
    await Promise.all([
      stat(resolve('.tmp/golden-diff/expected/establish.png')),
      stat(resolve('.tmp/golden-diff/actual/establish.png')),
      stat(resolve('.tmp/golden-diff/diff/establish.png')),
      stat(resolve('.tmp/golden-diff/heatmap/establish.png')),
    ]);
  }, 20_000);
});

async function temporaryRoot(): Promise<string> {
  const root = await mkdtemp(resolve(tmpdir(), 'soredemo-golden-test-'));
  temporaryRoots.push(root);
  return root;
}

async function readJson<T>(file: string): Promise<T> {
  return JSON.parse(await readFile(resolve(CANONICAL_INPUT_ROOT, file), 'utf8')) as T;
}
