import { describe, expect, it } from 'vitest';
import { validateProbeDocuments } from '../../src/encoder/ffprobe-validation.js';

function documents(overrides: Record<string, unknown> = {}) {
  const stream = {
    codec_type: 'video',
    codec_name: 'h264',
    profile: 'High',
    level: 40,
    pix_fmt: 'yuv420p',
    width: 1920,
    height: 1080,
    avg_frame_rate: '30/1',
    r_frame_rate: '30/1',
    nb_read_frames: '3',
    bit_rate: '1000000',
    color_primaries: 'bt709',
    color_transfer: 'bt709',
    color_space: 'bt709',
    color_range: 'tv',
    ...overrides,
  };
  return {
    metadata: {
      streams: [stream],
      format: { format_name: 'mov,mp4,m4a,3gp,3g2,mj2', duration: '0.100', bit_rate: '1000000' },
    },
    frameDocument: {
      frames: [0, 1, 2].map((index) => ({
        best_effort_timestamp_time: (index / 30).toFixed(6),
        duration_time: (1 / 30).toFixed(6),
      })),
    },
  };
}

function validate(overrides: Record<string, unknown> = {}) {
  return validateProbeDocuments({
    ...documents(overrides),
    width: 1920,
    height: 1080,
    fps: 30,
    frameCount: 3,
    fastStart: true,
  });
}

describe('FFprobe validation', () => {
  it('accepts one CFR H.264/yuv420p video stream', () => {
    const video = validate();
    expect(video.frameCount).toBe(3);
    expect(video.frames.at(-1)?.timestampSeconds).toBeCloseTo(2 / 30, 5);
    expect(video.fastStart).toBe(true);
  });

  it('rejects pixel format, frame count, and timing mismatches', () => {
    expect(() => validate({ pix_fmt: 'yuv444p' })).toThrow('yuv420p');
    expect(() => validate({ nb_read_frames: '2' })).toThrow('frame count');
    const invalidTiming = documents();
    const frames = invalidTiming.frameDocument.frames as Array<Record<string, string>>;
    const last = frames[2];
    if (last) last.best_effort_timestamp_time = '0.200000';
    expect(() =>
      validateProbeDocuments({
        ...invalidTiming,
        width: 1920,
        height: 1080,
        fps: 30,
        frameCount: 3,
        fastStart: true,
      }),
    ).toThrow('constant 30fps');
  });

  it('rejects missing fast-start ordering and extra streams', () => {
    expect(() =>
      validateProbeDocuments({
        ...documents(),
        width: 1920,
        height: 1080,
        fps: 30,
        frameCount: 3,
        fastStart: false,
      }),
    ).toThrow('moov');
    const extra = documents();
    extra.metadata.streams.push({ codec_type: 'audio' } as (typeof extra.metadata.streams)[number]);
    expect(() =>
      validateProbeDocuments({
        ...extra,
        width: 1920,
        height: 1080,
        fps: 30,
        frameCount: 3,
        fastStart: true,
      }),
    ).toThrow('exactly one stream');
  });
});
