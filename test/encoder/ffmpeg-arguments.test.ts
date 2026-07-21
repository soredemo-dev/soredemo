import { describe, expect, it } from 'vitest';
import { ffmpegArguments } from '../../src/encoder/ffmpeg-arguments.js';
import type { VideoEncodingConfig } from '../../src/encoder/types.js';

const config: VideoEncodingConfig = {
  outputPath: '/output/final.mp4',
  width: 1920,
  height: 1080,
  fps: 30,
  expectedFrameCount: 1751,
  codec: 'libx264',
  pixelFormat: 'yuv420p',
  preset: 'medium',
  crf: 18,
  overwrite: true,
};

describe('FFmpeg arguments', () => {
  it('builds the fixed raw-RGBA to CFR H.264 contract', () => {
    const args = ffmpegArguments(config, '/output/partial.mp4');
    expect(args).toContain('rgba');
    expect(args).toContain('1920x1080');
    expect(args).toContain('libx264');
    expect(args).toContain('yuv420p');
    expect(args).toContain('1751');
    expect(args).toContain('+faststart');
    expect(args.at(-1)).toBe('/output/partial.mp4');
    expect(args).not.toContain('-r');
  });

  it('rejects invalid output geometry and frame counts', () => {
    expect(() => ffmpegArguments({ ...config, width: 1919 }, '/tmp/a.mp4')).toThrow('even');
    expect(() => ffmpegArguments({ ...config, expectedFrameCount: 0 }, '/tmp/a.mp4')).toThrow(
      'frame count',
    );
  });
});
