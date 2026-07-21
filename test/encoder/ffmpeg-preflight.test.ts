import { describe, expect, it } from 'vitest';
import { parseFfmpegDiagnostics } from '../../src/encoder/ffmpeg-preflight.js';

const executable = {
  requestedName: 'ffmpeg',
  resolvedPath: '/tools/ffmpeg',
  realPath: '/tools/ffmpeg',
  source: 'path' as const,
};

function input() {
  return {
    ffmpeg: executable,
    ffprobe: { ...executable, requestedName: 'ffprobe' },
    executableSha256: 'a'.repeat(64),
    version:
      'ffmpeg version 8.0\nbuilt with test compiler\nconfiguration: --enable-gpl --enable-libx264',
    buildconf: '--enable-gpl\n--enable-libx264',
    encoders: ' V....D libx264 libx264 H.264 encoder',
    formats: ' DE rawvideo raw video',
    ffprobeVersionOutput: 'ffprobe version 8.0',
  };
}

describe('FFmpeg preflight parsing', () => {
  it('records GPL-conditioned libx264 and rawvideo capabilities', () => {
    const result = parseFfmpegDiagnostics(input());
    expect(result.gplEnabled).toBe(true);
    expect(result.libx264Enabled).toBe(true);
    expect(result.libx264EncoderPresent).toBe(true);
    expect(result.rawvideoInputPresent).toBe(true);
  });

  it('fails when libx264 or configuration diagnostics are absent', () => {
    expect(() => parseFfmpegDiagnostics({ ...input(), encoders: '' })).toThrow('libx264');
    expect(() => parseFfmpegDiagnostics({ ...input(), version: 'ffmpeg version 8.0' })).toThrow(
      'configuration',
    );
  });
});
