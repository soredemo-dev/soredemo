import type { Image } from '@napi-rs/canvas';
import { describe, expect, it } from 'vitest';
import { runComposition } from '../../src/compositor/frame-runner.js';
import {
  type CompositionFrameContext,
  type FrameCompositor,
  OUTPUT_HEIGHT,
  OUTPUT_WIDTH,
  type RawRgbaFrame,
  RGBA_BYTE_LENGTH,
  RGBA_STRIDE_BYTES,
  type SourceImageLoader,
  type SourceImageLoaderDiagnostics,
} from '../../src/compositor/types.js';
import type { ResampledFrameRecord } from '../../src/resample/types.js';
import { frameRecord } from './helpers.js';

async function* records(count: number): AsyncGenerator<ResampledFrameRecord> {
  for (let index = 0; index < count; index += 1) yield frameRecord(index, index + 1);
}

class FakeLoader implements SourceImageLoader {
  calls = 0;

  async load(): Promise<Image> {
    this.calls += 1;
    return {} as Image;
  }

  diagnostics(): SourceImageLoaderDiagnostics {
    return {
      decodeCount: this.calls,
      cacheHits: 0,
      cacheMisses: this.calls,
      maxDecodedImagesRetained: this.calls === 0 ? 0 : 1,
      outOfOrderSourceSelections: 0,
    };
  }
}

function fakeCompositor(onCompose?: (context: CompositionFrameContext) => void): FrameCompositor {
  const data = new Uint8Array(RGBA_BYTE_LENGTH);
  return {
    compose(context): RawRgbaFrame {
      onCompose?.(context);
      return {
        outputIndex: context.outputIndex,
        outputTimestampMs: context.outputTimestampMs,
        sourceIndex: context.sourceIndex,
        sourceTimestampMs: context.sourceTimestampMs,
        width: OUTPUT_WIDTH,
        height: OUTPUT_HEIGHT,
        strideBytes: RGBA_STRIDE_BYTES,
        byteLength: RGBA_BYTE_LENGTH,
        data,
      };
    },
  };
}

describe('sequential frame runner', () => {
  it('processes every record once in order while preserving both timestamps', async () => {
    const seen: Array<[number, number, number]> = [];
    const loader = new FakeLoader();
    const result = await runComposition({
      frames: records(3),
      sourceWidth: 2,
      sourceHeight: 1,
      loader,
      compositor: fakeCompositor(),
      consumer: {
        async consume(frame) {
          seen.push([frame.outputIndex, frame.outputTimestampMs, frame.sourceTimestampMs]);
        },
      },
    });
    expect(seen).toEqual([
      [0, 0, 2],
      [1, 1000 / 30, 1000 / 30 + 2],
      [2, 2000 / 30, 2000 / 30 + 2],
    ]);
    expect(result.framesProcessed).toBe(3);
    expect(result.bytesProcessed).toBe(3 * RGBA_BYTE_LENGTH);
    expect(result.maxActiveFrames).toBe(1);
  });

  it('awaits consumer backpressure before composing the next frame', async () => {
    let composed = 0;
    let release: (() => void) | undefined;
    let firstConsumed: (() => void) | undefined;
    const entered = new Promise<void>((resolve) => {
      firstConsumed = resolve;
    });
    const blocked = new Promise<void>((resolve) => {
      release = resolve;
    });
    const run = runComposition({
      frames: records(2),
      sourceWidth: 2,
      sourceHeight: 1,
      loader: new FakeLoader(),
      compositor: fakeCompositor(() => {
        composed += 1;
      }),
      consumer: {
        async consume(frame) {
          if (frame.outputIndex === 0) {
            firstConsumed?.();
            await blocked;
          }
        },
      },
    });
    await entered;
    expect(composed).toBe(1);
    release?.();
    await run;
    expect(composed).toBe(2);
  });

  it('stops cleanly at the first consumer error', async () => {
    let composed = 0;
    const run = runComposition({
      frames: records(3),
      sourceWidth: 2,
      sourceHeight: 1,
      loader: new FakeLoader(),
      compositor: fakeCompositor(() => {
        composed += 1;
      }),
      consumer: {
        async consume(frame) {
          if (frame.outputIndex === 1) throw new Error('sink failed');
        },
      },
    });
    await expect(run).rejects.toThrow('sink failed');
    expect(composed).toBe(2);
  });

  it('rejects missing or reordered output records', async () => {
    async function* missing(): AsyncGenerator<ResampledFrameRecord> {
      yield frameRecord(0);
      yield frameRecord(2);
    }
    await expect(
      runComposition({
        frames: missing(),
        sourceWidth: 2,
        sourceHeight: 1,
        loader: new FakeLoader(),
        compositor: fakeCompositor(),
        consumer: { async consume() {} },
      }),
    ).rejects.toThrow('ordered and consecutive');
  });
});
