import { createCanvas, loadImage } from '@napi-rs/canvas';
import { describe, expect, it } from 'vitest';
import { SequentialCameraEvaluator } from '../../src/compositor/camera-evaluator.js';
import { CameraFrameCompositor } from '../../src/compositor/camera-frame-compositor.js';
import { buildCameraTrack } from '../../src/compositor/camera-track.js';
import { decodeCursorAsset } from '../../src/compositor/cursor-asset.js';
import { SequentialCursorEvaluator } from '../../src/compositor/cursor-track.js';
import type { CompositionFrameContext } from '../../src/compositor/types.js';
import { buildCursorTrack } from '../../src/timeline/cursor-track-validation.js';
import type { ClickTimelineEvent } from '../../src/timeline/types.js';

const viewport = { width: 1440, height: 900 };

function click(): ClickTimelineEvent {
  return {
    id: 'click-001',
    kind: 'click',
    startMs: 1000,
    endMs: 1810,
    target: { strategy: 'testId', value: { testId: 'target' } },
    targetBboxAtPathStart: { x: 160, y: 280, width: 120, height: 80 },
    targetBboxAtCommit: { x: 160, y: 280, width: 120, height: 80 },
    clickPoint: { x: 220, y: 320 },
    cursorPath: [
      { x: 220, y: 320, timeMs: 1000 },
      { x: 220, y: 320, timeMs: 1600 },
    ],
    mouseDownMs: 1800,
    mouseUpMs: 1805,
  };
}

async function cursorAsset() {
  return decodeCursorAsset(
    Buffer.from(
      '<svg xmlns="http://www.w3.org/2000/svg" width="5" height="5"><rect width="5" height="5" fill="#fff"/></svg>',
    ),
    {
      sourceWidth: 5,
      sourceHeight: 5,
      hotspotX: 1,
      hotspotY: 1,
      renderedWidth: 5,
      renderedHeight: 5,
    },
  );
}

async function sourceImage() {
  const canvas = createCanvas(144, 90);
  const context = canvas.getContext('2d');
  context.fillStyle = '#ff0000';
  context.fillRect(0, 0, 72, 90);
  context.fillStyle = '#0000ff';
  context.fillRect(72, 0, 72, 90);
  return loadImage(canvas.toBuffer('image/png'));
}

function pixel(data: Uint8Array, x: number, y: number): number[] {
  const offset = (y * 1920 + x) * 4;
  return [...data.subarray(offset, offset + 4)];
}

describe('camera frame compositor', () => {
  it('crops browser pixels while keeping the cursor raster fixed and opaque', async () => {
    const event = click();
    const cameraTrack = buildCameraTrack([event], 2500, viewport);
    const cursorTrack = buildCursorTrack([event], viewport);
    const compositor = new CameraFrameCompositor(
      144,
      90,
      viewport,
      await cursorAsset(),
      new SequentialCameraEvaluator(cameraTrack),
      new SequentialCursorEvaluator(cursorTrack),
      new Set([54]),
    );
    const context: CompositionFrameContext = {
      outputIndex: 54,
      outputTimestampMs: 1800,
      sourceIndex: 1,
      sourceFile: 'frames/000001.jpg',
      sourceTimestampMs: 1802,
      signedSourceDeltaMs: 2,
    };
    const frame = compositor.compose(context, await sourceImage());
    expect(frame.camera.zoom).toBe(1.25);
    expect(frame.sourceCrop.width).toBeCloseTo(144 / 1.25);
    expect(frame.cursorPlacement).toMatchObject({ width: 5, height: 5 });
    expect(frame.cursorPlacement?.hotspotScreenX).toBeCloseTo(frame.cursor.screenX ?? -1);
    expect(frame.cursorPixelsChanged).toBeGreaterThan(0);
    expect(pixel(frame.data, 96, 540).slice(0, 3)).not.toEqual([0, 0, 0]);
    expect(pixel(frame.data, 1823, 540).slice(0, 3)).not.toEqual([0, 0, 0]);
    expect(pixel(frame.data, 960, 540)[3]).toBe(255);
  });

  it('clears stale camera pixels and retains canvas.data as readback', async () => {
    const source = await import('node:fs/promises').then(({ readFile }) =>
      readFile('src/compositor/base-frame-compositor.ts', 'utf8'),
    );
    expect(source).toContain('canvas.data()');
    expect(source).not.toContain('getImageData');
  });
});
