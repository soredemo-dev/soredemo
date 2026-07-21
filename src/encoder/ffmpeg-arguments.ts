import type { VideoEncodingConfig } from './types.js';

export function validateEncodingConfig(config: VideoEncodingConfig): void {
  if (
    !Number.isInteger(config.width) ||
    !Number.isInteger(config.height) ||
    config.width < 2 ||
    config.height < 2 ||
    config.width % 2 !== 0 ||
    config.height % 2 !== 0
  ) {
    throw new Error('H.264 output dimensions must be positive even integers');
  }
  if (!Number.isInteger(config.fps) || config.fps <= 0) {
    throw new Error('FPS must be a positive integer');
  }
  if (!Number.isInteger(config.expectedFrameCount) || config.expectedFrameCount < 1) {
    throw new Error('Expected frame count must be a positive integer');
  }
}

export function ffmpegArguments(config: VideoEncodingConfig, temporaryOutput: string): string[] {
  validateEncodingConfig(config);
  return [
    '-hide_banner',
    '-nostdin',
    '-loglevel',
    'warning',
    '-f',
    'rawvideo',
    '-pixel_format',
    'rgba',
    '-video_size',
    `${config.width}x${config.height}`,
    '-framerate',
    String(config.fps),
    '-i',
    'pipe:0',
    '-an',
    '-c:v',
    config.codec,
    '-preset',
    config.preset,
    '-crf',
    String(config.crf),
    '-pix_fmt',
    config.pixelFormat,
    '-fps_mode',
    'cfr',
    '-g',
    String(config.fps * 2),
    '-keyint_min',
    String(config.fps),
    '-sc_threshold',
    '0',
    '-color_primaries',
    'bt709',
    '-color_trc',
    'bt709',
    '-colorspace',
    'bt709',
    '-color_range',
    'tv',
    '-frames:v',
    String(config.expectedFrameCount),
    '-map_metadata',
    '-1',
    '-metadata',
    'creation_time=1970-01-01T00:00:00Z',
    '-movflags',
    '+faststart',
    '-y',
    temporaryOutput,
  ];
}
