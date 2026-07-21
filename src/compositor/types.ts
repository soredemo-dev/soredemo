import type { Image } from '@napi-rs/canvas';
import type { ResampledFrameRecord } from '../resample/types.js';

export const OUTPUT_WIDTH = 1920 as const;
export const OUTPUT_HEIGHT = 1080 as const;
export const OUTPUT_FPS = 30 as const;
export const RGBA_STRIDE_BYTES = 7680 as const;
export const RGBA_BYTE_LENGTH = 8_294_400 as const;

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface CompositionFrameContext {
  outputIndex: number;
  outputTimestampMs: number;
  sourceIndex: number;
  sourceFile: string;
  sourceTimestampMs: number;
  signedSourceDeltaMs: number;
}

export interface RawRgbaFrame {
  outputIndex: number;
  outputTimestampMs: number;
  sourceIndex: number;
  sourceTimestampMs: number;
  width: typeof OUTPUT_WIDTH;
  height: typeof OUTPUT_HEIGHT;
  strideBytes: typeof RGBA_STRIDE_BYTES;
  byteLength: typeof RGBA_BYTE_LENGTH;
  data: Uint8Array;
}

export interface FrameConsumer {
  consume(frame: RawRgbaFrame): Promise<void>;
}

export interface FrameCompositor {
  compose(frameContext: CompositionFrameContext, image: Image): RawRgbaFrame;
}

export interface SourceImageLoader {
  load(record: ResampledFrameRecord): Promise<Image>;
  diagnostics(): SourceImageLoaderDiagnostics;
}

export interface SourceImageLoaderDiagnostics {
  decodeCount: number;
  cacheHits: number;
  cacheMisses: number;
  maxDecodedImagesRetained: number;
  outOfOrderSourceSelections: number;
}

export interface CompositionRunSummary {
  framesProcessed: number;
  bytesProcessed: number;
  maxActiveFrames: number;
  sourceImages: SourceImageLoaderDiagnostics;
}

export interface ComposedFrameHashRecord {
  outputIndex: number;
  outputTimestampMs: number;
  sourceIndex: number;
  sourceTimestampMs: number;
  rgbaSha256: string;
}

export interface SnapshotRecord {
  purpose: string;
  outputIndex: number;
  outputTimestampMs: number;
  sourceIndex: number;
  sourceTimestampMs: number;
  file: string;
  pngSha256: string;
}

export interface CompositionManifest {
  schemaVersion: 1;
  sourceCapturePath: string;
  sourceResamplePlanPath: string;
  sourcePixelWidth: number;
  sourcePixelHeight: number;
  outputWidth: typeof OUTPUT_WIDTH;
  outputHeight: typeof OUTPUT_HEIGHT;
  outputFps: typeof OUTPUT_FPS;
  outputFrameCount: number;
  pixelFormat: 'rgba';
  channelOrder: 'rgba';
  alphaMode: 'opaque';
  fitMode: 'contain';
  contentRect: Rect;
  matte: { red: 0; green: 0; blue: 0; alpha: 255 };
  canvasPackage: { name: '@napi-rs/canvas'; version: string };
  decoding: {
    decodeCount: number;
    cacheHits: number;
    cacheMisses: number;
    maxDecodedImagesRetained: number;
  };
  bytesProcessed: number;
  rollingRgbaSha256: string;
  snapshots: SnapshotRecord[];
  performance: {
    executionMs: number;
    framesPerSecond: number;
    rssBeforeBytes: number;
    rssAfterBytes: number;
    peakRssBytes: number;
  };
}
