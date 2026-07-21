import type { RawRgbaFrame } from '../compositor/types.js';

export interface ResolvedExecutable {
  requestedName: string;
  resolvedPath: string;
  realPath: string;
  source: 'environment' | 'path';
}

export interface FfmpegCapabilities {
  ffmpeg: ResolvedExecutable;
  ffprobe: ResolvedExecutable;
  executableSha256: string;
  ffmpegVersion: string;
  ffprobeVersion: string;
  compilerLine?: string;
  configureArguments: string;
  gplEnabled: boolean;
  libx264Enabled: boolean;
  libx264EncoderPresent: boolean;
  rawvideoInputPresent: boolean;
  raw: {
    version: string;
    buildconf: string;
    encoders: string;
    formats: string;
    ffprobeVersion: string;
  };
}

export interface VideoEncodingConfig {
  outputPath: string;
  width: number;
  height: number;
  fps: number;
  expectedFrameCount: number;
  codec: 'libx264';
  pixelFormat: 'yuv420p';
  preset: 'medium';
  crf: 18;
  overwrite: boolean;
}

export interface EncoderBackpressureStatistics {
  framesWritten: number;
  writeFalseCount: number;
  drainCount: number;
  maxPendingFrames: number;
  maxPendingBytes: number;
  writeLatencyMs: {
    median: number;
    p95: number;
    max: number;
  };
}

export interface EncodedVideoResult {
  outputPath: string;
  frameCount: number;
  byteLength: number;
  sha256: string;
  executionMs: number;
  ffmpegExitCode: number;
  ffmpegSignal: NodeJS.Signals | null;
  backpressure: EncoderBackpressureStatistics;
}

export interface EncoderSession {
  consume(frame: RawRgbaFrame): Promise<void>;
  finalize(): Promise<EncodedVideoResult>;
  abort(reason: unknown): Promise<void>;
}

export interface FfprobeFrameTiming {
  index: number;
  timestampSeconds: number;
  durationSeconds: number;
}

export interface ValidatedVideo {
  codecName: 'h264';
  profile: string;
  level: number;
  pixelFormat: 'yuv420p';
  width: number;
  height: number;
  averageFrameRate: number;
  realFrameRate: number;
  frameCount: number;
  durationSeconds: number;
  bitRate: number;
  audioStreams: 0;
  formatName: string;
  colorPrimaries?: string;
  colorTransfer?: string;
  colorSpace?: string;
  colorRange?: string;
  frames: FfprobeFrameTiming[];
  fastStart: boolean;
}
