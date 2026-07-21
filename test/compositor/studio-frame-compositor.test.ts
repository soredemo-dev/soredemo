import { readFile } from 'node:fs/promises';
import { createCanvas, loadImage } from '@napi-rs/canvas';
import { describe, expect, it } from 'vitest';
import { SequentialCameraEvaluator } from '../../src/compositor/camera-evaluator.js';
import { buildCameraTrack } from '../../src/compositor/camera-track.js';
import {
  buildClickFeedbackTrack,
  SequentialClickFeedbackEvaluator,
} from '../../src/compositor/click-feedback-track.js';
import { loadCursorAsset } from '../../src/compositor/cursor-asset.js';
import { SequentialCursorEvaluator } from '../../src/compositor/cursor-track.js';
import { drawStudioGradient } from '../../src/compositor/gradient-background.js';
import { StudioFrameCompositor } from '../../src/compositor/studio-frame-compositor.js';
import type { CompositionFrameContext } from '../../src/compositor/types.js';
import { buildCursorTrack } from '../../src/timeline/cursor-track-validation.js';
import type { ClickTimelineEvent } from '../../src/timeline/types.js';

const viewport = { width: 1440, height: 900 };

function fixtureClick(): ClickTimelineEvent {
  return {
    id: 'click-001',
    kind: 'click',
    startMs: 1000,
    endMs: 1810,
    target: { strategy: 'testId', value: { testId: 'static-target' } },
    targetBboxAtPathStart: { x: 280, y: 260, width: 80, height: 60 },
    targetBboxAtCommit: { x: 280, y: 260, width: 80, height: 60 },
    clickPoint: { x: 320, y: 290 },
    cursorPath: [
      { x: 200, y: 200, timeMs: 1000 },
      { x: 320, y: 290, timeMs: 1600 },
    ],
    mouseDownMs: 1800,
    mouseUpMs: 1805,
  };
}

async function sourceImage() {
  const canvas = createCanvas(144, 90);
  const context = canvas.getContext('2d');
  context.fillStyle = '#eef1f8';
  context.fillRect(0, 0, 144, 90);
  context.fillStyle = '#2563eb';
  context.fillRect(20, 20, 30, 20);
  return loadImage(canvas.toBuffer('image/png'));
}

function pixel(data: Uint8Array, x: number, y: number): number[] {
  const offset = (y * 1920 + x) * 4;
  return [...data.subarray(offset, offset + 4)];
}

describe('studio frame compositor', () => {
  it('renders the complete ordered studio stack with a fixed cursor and ripple', async () => {
    const click = fixtureClick();
    const cameraTrack = buildCameraTrack([click], 2500, viewport);
    const cursorTrack = buildCursorTrack([click], viewport);
    const compositor = new StudioFrameCompositor(
      144,
      90,
      viewport,
      await loadCursorAsset('assets/cursor.svg'),
      new SequentialCameraEvaluator(cameraTrack),
      new SequentialCursorEvaluator(cursorTrack),
      new SequentialClickFeedbackEvaluator(buildClickFeedbackTrack([click])),
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
    expect(frame.ripples).toHaveLength(1);
    expect(frame.ripples[0]).toMatchObject({ radius: 3, opacity: 0.55 });
    expect(frame.cursorPlacement).toMatchObject({ width: 30, height: 38 });
    expect(frame.cursorPixelsChanged).toBeGreaterThan(0);
    expect(pixel(frame.data, 0, 0).slice(0, 3)).not.toEqual([0, 0, 0]);
    expect(pixel(frame.data, 240, 64).slice(0, 3)).not.toEqual([245, 245, 247]);
    expect(pixel(frame.data, 262, 90).slice(0, 3)).toEqual([255, 95, 87]);
    expect(pixel(frame.data, 960, 64)).not.toEqual([245, 245, 247, 255]);
    expect(pixel(frame.data, 300, 150).slice(0, 3)).not.toEqual(
      pixel(frame.data, 0, 0).slice(0, 3),
    );
    expect(pixel(frame.data, 240, 1015).slice(0, 3)).not.toEqual([238, 241, 248]);
    expect(frame.data.filter((_, index) => index % 4 === 3).every((alpha) => alpha === 255)).toBe(
      true,
    );
    const ripple = frame.ripples[0];
    if (!ripple) throw new Error('missing rendered ripple');
    expect(
      pixel(frame.data, Math.floor(ripple.screenX - ripple.radius), Math.floor(ripple.screenY))[0],
    ).toBeGreaterThan(100);

    const gradient = createCanvas(1920, 1080);
    drawStudioGradient(gradient.getContext('2d'));
    expect(pixel(frame.data, 960, 1035)).not.toEqual(pixel(gradient.data(), 960, 1035));
  });

  it('retains canvas.data readback and never adds getImageData', async () => {
    const source = await readFile('src/compositor/studio-frame-compositor.ts', 'utf8');
    expect(source).toContain('outputCanvas.data()');
    expect(source).not.toContain('getImageData');
  });
});
