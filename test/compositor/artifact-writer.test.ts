import { mkdtemp, readdir, readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { loadImage } from '@napi-rs/canvas';
import { describe, expect, it } from 'vitest';
import {
  DiagnosticFrameSink,
  writeCompositionManifest,
} from '../../src/compositor/artifact-writer.js';
import { BaseFrameCompositor } from '../../src/compositor/base-frame-compositor.js';
import type { CompositionManifest } from '../../src/compositor/types.js';
import { solidImage } from './helpers.js';

async function directory(): Promise<string> {
  return mkdtemp(join(tmpdir(), 'soredemo-compositor-artifact-'));
}

describe('composition artifact writer', () => {
  it('writes incremental hashes and stable snapshots without raw frame files', async () => {
    const output = await directory();
    const compositor = new BaseFrameCompositor(2, 1);
    const sink = await DiagnosticFrameSink.create(
      output,
      compositor,
      new Map([[0, 'first frame']]),
    );
    const frame = compositor.compose(
      {
        outputIndex: 0,
        outputTimestampMs: 0,
        sourceIndex: 1,
        sourceFile: 'frames/000001.jpg',
        sourceTimestampMs: 2,
        signedSourceDeltaMs: 2,
      },
      await solidImage(2, 1, '#4488cc'),
    );
    await sink.consume(frame);
    const result = await sink.finish();
    expect(result.frameCount).toBe(1);
    expect(result.rollingRgbaSha256).toMatch(/^[a-f0-9]{64}$/);
    expect(result.snapshots).toHaveLength(1);
    expect(result.snapshots[0]?.file).toBe('snapshots/frame-000000.png');

    const lines = (await readFile(resolve(output, 'frame-hashes.jsonl'), 'utf8'))
      .trim()
      .split('\n');
    expect(lines).toHaveLength(1);
    expect(JSON.parse(lines[0] ?? '{}').rgbaSha256).toMatch(/^[a-f0-9]{64}$/);
    const snapshot = await loadImage(resolve(output, 'snapshots/frame-000000.png'));
    expect([snapshot.width, snapshot.height]).toEqual([1920, 1080]);
    expect(
      (await readdir(output, { recursive: true })).some((name) => name.endsWith('.rgba')),
    ).toBe(false);
  });

  it('serializes identical manifests deterministically', async () => {
    const first = await directory();
    const second = await directory();
    const manifest: CompositionManifest = {
      schemaVersion: 1,
      sourceCapturePath: 'capture',
      sourceResamplePlanPath: 'plan',
      sourcePixelWidth: 2880,
      sourcePixelHeight: 1800,
      outputWidth: 1920,
      outputHeight: 1080,
      outputFps: 30,
      outputFrameCount: 1,
      pixelFormat: 'rgba',
      channelOrder: 'rgba',
      alphaMode: 'opaque',
      fitMode: 'contain',
      contentRect: { x: 96, y: 0, width: 1728, height: 1080 },
      matte: { red: 0, green: 0, blue: 0, alpha: 255 },
      canvasPackage: { name: '@napi-rs/canvas', version: '1.0.2' },
      decoding: { decodeCount: 1, cacheHits: 0, cacheMisses: 1, maxDecodedImagesRetained: 1 },
      bytesProcessed: 8_294_400,
      rollingRgbaSha256: 'a'.repeat(64),
      snapshots: [],
      performance: {
        executionMs: 1,
        framesPerSecond: 1000,
        rssBeforeBytes: 1,
        rssAfterBytes: 1,
        peakRssBytes: 1,
      },
    };
    await writeCompositionManifest(first, manifest);
    await writeCompositionManifest(second, manifest);
    expect(await readFile(resolve(first, 'manifest.json'), 'utf8')).toBe(
      await readFile(resolve(second, 'manifest.json'), 'utf8'),
    );
    expect((await stat(resolve(first, 'manifest.json'))).isFile()).toBe(true);
  });
});
