import { hasFastStart, readTopLevelMp4Boxes } from './mp4-boxes.js';
import { requireSuccessfulProcess, runCapturedProcess } from './subprocess.js';
import type { ResolvedExecutable, ValidatedVideo } from './types.js';

type JsonRecord = Record<string, unknown>;

function object(value: unknown, label: string): JsonRecord {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value as JsonRecord;
}

function string(value: unknown, label: string): string {
  if (typeof value !== 'string' || value.length === 0) throw new Error(`${label} must be a string`);
  return value;
}

function finite(value: unknown, label: string): number {
  const parsed = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(parsed)) throw new Error(`${label} must be finite`);
  return parsed;
}

function integer(value: unknown, label: string): number {
  const parsed = finite(value, label);
  if (!Number.isInteger(parsed)) throw new Error(`${label} must be an integer`);
  return parsed;
}

function rate(value: unknown, label: string): number {
  const raw = string(value, label);
  const [numerator, denominator, extra] = raw.split('/');
  if (extra !== undefined || numerator === undefined || denominator === undefined) {
    throw new Error(`${label} must be a fraction`);
  }
  const divisor = Number(denominator);
  const parsed = Number(numerator) / divisor;
  if (!Number.isFinite(parsed) || divisor === 0) throw new Error(`${label} is invalid`);
  return parsed;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

async function ffprobeJson(
  executable: string,
  arguments_: readonly string[],
  description: string,
): Promise<JsonRecord> {
  const result = requireSuccessfulProcess(
    await runCapturedProcess({
      executable,
      arguments: ['-hide_banner', '-v', 'error', ...arguments_, '-of', 'json'],
      maxOutputBytes: 32 * 1024 * 1024,
      timeoutMs: 60_000,
    }),
    description,
  );
  try {
    return object(JSON.parse(result.stdout.toString('utf8')), `${description} JSON`);
  } catch (error) {
    if (error instanceof SyntaxError) throw new Error(`${description} returned malformed JSON`);
    throw error;
  }
}

export async function validateEncodedVideo(options: {
  file: string;
  ffprobe: ResolvedExecutable;
  ffmpeg: ResolvedExecutable;
  width: number;
  height: number;
  fps: number;
  frameCount: number;
}): Promise<{ video: ValidatedVideo; ffprobeJson: JsonRecord; decodeStderr: string }> {
  const metadata = await ffprobeJson(
    options.ffprobe.resolvedPath,
    ['-count_frames', '-show_streams', '-show_format', options.file],
    'FFprobe metadata inspection',
  );
  const frameDocument = await ffprobeJson(
    options.ffprobe.resolvedPath,
    [
      '-select_streams',
      'v:0',
      '-show_frames',
      '-show_entries',
      'frame=best_effort_timestamp_time,pkt_duration_time,duration_time',
      options.file,
    ],
    'FFprobe frame timing inspection',
  );
  const fastStart = hasFastStart(await readTopLevelMp4Boxes(options.file));
  const video = validateProbeDocuments({
    metadata,
    frameDocument,
    width: options.width,
    height: options.height,
    fps: options.fps,
    frameCount: options.frameCount,
    fastStart,
  });

  const decode = requireSuccessfulProcess(
    await runCapturedProcess({
      executable: options.ffmpeg.resolvedPath,
      arguments: ['-hide_banner', '-v', 'error', '-i', options.file, '-f', 'null', '-'],
      maxOutputBytes: 1024 * 1024,
      timeoutMs: 120_000,
    }),
    'FFmpeg decode smoke test',
  );
  if (decode.stderr.byteLength > 0) throw new Error('FFmpeg decode smoke test emitted errors');
  return { video, ffprobeJson: metadata, decodeStderr: decode.stderr.toString('utf8') };
}

export function validateProbeDocuments(options: {
  metadata: JsonRecord;
  frameDocument: JsonRecord;
  width: number;
  height: number;
  fps: number;
  frameCount: number;
  fastStart: boolean;
}): ValidatedVideo {
  const metadata = options.metadata;
  const streams = metadata.streams;
  if (!Array.isArray(streams) || streams.length !== 1) {
    throw new Error('Encoded MP4 must contain exactly one stream');
  }
  const stream = object(streams[0], 'video stream');
  if (stream.codec_type !== 'video') throw new Error('Encoded MP4 stream must be video');
  if (stream.codec_name !== 'h264') throw new Error('Encoded video codec must be h264');
  if (stream.pix_fmt !== 'yuv420p') throw new Error('Encoded video pixel format must be yuv420p');
  if (integer(stream.width, 'video width') !== options.width)
    throw new Error('Video width mismatch');
  if (integer(stream.height, 'video height') !== options.height)
    throw new Error('Video height mismatch');
  const averageFrameRate = rate(stream.avg_frame_rate, 'average frame rate');
  const realFrameRate = rate(stream.r_frame_rate, 'real frame rate');
  if (Math.abs(averageFrameRate - options.fps) > 1e-9) {
    throw new Error('Average frame rate does not match configuration');
  }
  if (Math.abs(realFrameRate - options.fps) > 1e-9) {
    throw new Error('Real frame rate does not match configuration');
  }
  if (integer(stream.nb_read_frames, 'decoded frame count') !== options.frameCount) {
    throw new Error('Decoded frame count does not match configuration');
  }
  const format = object(metadata.format, 'format');
  const formatName = string(format.format_name, 'format name');
  if (!formatName.split(',').some((name) => name === 'mov' || name === 'mp4')) {
    throw new Error('Output is not an MP4/MOV-family container');
  }
  const durationSeconds = finite(format.duration, 'format duration');
  const expectedDuration = options.frameCount / options.fps;
  if (durationSeconds <= 0 || Math.abs(durationSeconds - expectedDuration) > 1 / options.fps) {
    throw new Error('Encoded duration does not match fixed-rate frame count');
  }

  const frameDocument = options.frameDocument;
  if (!Array.isArray(frameDocument.frames) || frameDocument.frames.length !== options.frameCount) {
    throw new Error('FFprobe frame-timing count mismatch');
  }
  const rawFrames = frameDocument.frames;
  const expectedFrameDuration = 1 / options.fps;
  const frames = rawFrames.map((value, index) => {
    const frame = object(value, `frame ${index}`);
    const timestampSeconds = finite(frame.best_effort_timestamp_time, `frame ${index} timestamp`);
    const durationSeconds = finite(
      frame.duration_time ?? frame.pkt_duration_time,
      `frame ${index} duration`,
    );
    if (index > 0) {
      const previous = object(rawFrames[index - 1], `frame ${index - 1}`);
      const previousTimestamp = finite(
        previous.best_effort_timestamp_time,
        `frame ${index - 1} timestamp`,
      );
      const delta = timestampSeconds - previousTimestamp;
      if (delta <= 0 || Math.abs(delta - expectedFrameDuration) > 1e-5) {
        throw new Error(`Frame ${index} violates constant 30fps timing`);
      }
    }
    if (Math.abs(durationSeconds - expectedFrameDuration) > 1e-5) {
      throw new Error(`Frame ${index} duration violates constant 30fps timing`);
    }
    return { index, timestampSeconds, durationSeconds };
  });
  const finalFrame = frames.at(-1);
  if (
    !finalFrame ||
    Math.abs(finalFrame.timestampSeconds - (options.frameCount - 1) / options.fps) > 1e-5
  ) {
    throw new Error('Final encoded frame timestamp is incorrect');
  }

  if (!options.fastStart) throw new Error('MP4 moov box does not precede mdat');
  const colorPrimaries = optionalString(stream.color_primaries);
  const colorTransfer = optionalString(stream.color_transfer);
  const colorSpace = optionalString(stream.color_space);
  const colorRange = optionalString(stream.color_range);

  return {
    codecName: 'h264',
    profile: string(stream.profile, 'codec profile'),
    level: integer(stream.level, 'codec level'),
    pixelFormat: 'yuv420p',
    width: options.width,
    height: options.height,
    averageFrameRate,
    realFrameRate,
    frameCount: options.frameCount,
    durationSeconds,
    bitRate: finite(stream.bit_rate ?? format.bit_rate, 'video bitrate'),
    audioStreams: 0,
    formatName,
    ...(colorPrimaries ? { colorPrimaries } : {}),
    ...(colorTransfer ? { colorTransfer } : {}),
    ...(colorSpace ? { colorSpace } : {}),
    ...(colorRange ? { colorRange } : {}),
    frames,
    fastStart: options.fastStart,
  };
}
