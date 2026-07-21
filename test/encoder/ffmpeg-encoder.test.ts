import { chmod, mkdtemp, readdir, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { RawRgbaFrame } from '../../src/compositor/types.js';
import {
  OUTPUT_HEIGHT,
  OUTPUT_WIDTH,
  RGBA_BYTE_LENGTH,
  RGBA_STRIDE_BYTES,
} from '../../src/compositor/types.js';
import { FfmpegEncoder } from '../../src/encoder/ffmpeg-encoder.js';
import type { ResolvedExecutable, VideoEncodingConfig } from '../../src/encoder/types.js';

async function fakeFfmpeg(directory: string): Promise<ResolvedExecutable> {
  const file = join(directory, 'fake-ffmpeg');
  await writeFile(
    file,
    [
      '#!/usr/bin/env node',
      "import { writeFileSync } from 'node:fs';",
      'const output = process.argv.at(-1);',
      'let bytes = 0;',
      "process.stdin.on('data', chunk => { bytes += chunk.length; if (output.includes('noisy')) process.stderr.write('x'.repeat(4096)); if (output.includes('early') || output.includes('noisy')) process.exit(9); });",
      "process.stdin.on('end', () => { writeFileSync(output, String(bytes)); });",
    ].join('\n'),
  );
  await chmod(file, 0o755);
  return { requestedName: 'ffmpeg', resolvedPath: file, realPath: file, source: 'path' };
}

function config(outputPath: string, frameCount = 1): VideoEncodingConfig {
  return {
    outputPath,
    width: OUTPUT_WIDTH,
    height: OUTPUT_HEIGHT,
    fps: 30,
    expectedFrameCount: frameCount,
    codec: 'libx264',
    pixelFormat: 'yuv420p',
    preset: 'medium',
    crf: 18,
    overwrite: true,
  };
}

function frame(index = 0) {
  return {
    outputIndex: index,
    outputTimestampMs: (index * 1000) / 30,
    sourceIndex: index + 1,
    sourceTimestampMs: index * 30,
    width: OUTPUT_WIDTH,
    height: OUTPUT_HEIGHT,
    strideBytes: RGBA_STRIDE_BYTES,
    byteLength: RGBA_BYTE_LENGTH,
    data: new Uint8Array(RGBA_BYTE_LENGTH),
  } as const;
}

describe.skipIf(process.platform === 'win32')('FFmpeg encoder session', () => {
  it('writes one frame with backpressure and atomically finalizes', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'soredemo-encoder-success-'));
    const output = join(directory, 'video.mp4');
    const encoder = await FfmpegEncoder.create({
      executable: await fakeFfmpeg(directory),
      config: config(output),
      logPath: join(directory, 'ffmpeg.log'),
      validateTemporary: async (file) => {
        expect(Number(await readFile(file, 'utf8'))).toBe(RGBA_BYTE_LENGTH);
      },
    });
    await encoder.consume(frame());
    const result = await encoder.finalize();
    expect(result.frameCount).toBe(1);
    expect(result.backpressure.maxPendingFrames).toBe(1);
    expect(result.backpressure.maxPendingBytes).toBe(RGBA_BYTE_LENGTH);
    expect((await readdir(directory)).some((file) => file.includes('.partial.'))).toBe(false);
    await expect(encoder.finalize()).rejects.toThrow('finalized');
    await expect(encoder.consume(frame())).rejects.toThrow('finalized');
  });

  it('rejects ordering and removes partial output after abort', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'soredemo-encoder-abort-'));
    const output = join(directory, 'video.mp4');
    await writeFile(output, 'previous');
    const encoder = await FfmpegEncoder.create({
      executable: await fakeFfmpeg(directory),
      config: config(output, 2),
      logPath: join(directory, 'ffmpeg.log'),
      validateTemporary: async () => {},
    });
    await expect(encoder.consume(frame(1))).rejects.toThrow('Expected encoder frame 0');
    await encoder.abort(new Error('test abort'));
    expect(await readFile(output, 'utf8')).toBe('previous');
    expect((await readdir(directory)).some((file) => file.includes('.partial.'))).toBe(false);
    await expect(encoder.consume(frame())).rejects.toThrow('aborted');
  });

  it('rejects wrong byte layout and too-short finalization', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'soredemo-encoder-layout-'));
    const encoder = await FfmpegEncoder.create({
      executable: await fakeFfmpeg(directory),
      config: config(join(directory, 'video.mp4'), 2),
      logPath: join(directory, 'ffmpeg.log'),
      validateTemporary: async () => {},
    });
    await expect(
      encoder.consume({
        ...frame(),
        byteLength: 4,
        data: new Uint8Array(4),
      } as unknown as RawRgbaFrame),
    ).rejects.toThrow('layout');
    await expect(encoder.finalize()).rejects.toThrow('0 of 2');
  });

  it('bounds stderr diagnostics and cleans up an early child failure', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'soredemo-encoder-early-'));
    const encoder = await FfmpegEncoder.create({
      executable: await fakeFfmpeg(directory),
      config: config(join(directory, 'noisy.mp4')),
      logPath: join(directory, 'ffmpeg.log'),
      validateTemporary: async () => {},
      stderrTailBytes: 128,
    });
    await expect(encoder.consume(frame())).rejects.toThrow();
    expect(encoder.stderrTailText().length).toBeLessThanOrEqual(128);
    await encoder.abort(new Error('child failed'));
    expect((await readdir(directory)).some((file) => file.includes('.partial.'))).toBe(false);
  });
});
