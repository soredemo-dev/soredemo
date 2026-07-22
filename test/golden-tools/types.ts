import type { CameraFrameState } from '../../src/compositor/camera-types.js';
import type { ClickRippleFrameState } from '../../src/compositor/click-feedback-track.js';
import type { CursorFrameState } from '../../src/compositor/cursor-track.js';
import type { Rect } from '../../src/compositor/types.js';

export type GoldenErrorCode =
  | 'GOLDEN_PROFILE_MISMATCH'
  | 'GOLDEN_INPUT_CHANGED'
  | 'GOLDEN_FRAME_MISSING'
  | 'GOLDEN_RGBA_MISMATCH'
  | 'GOLDEN_STRUCTURE_MISMATCH'
  | 'GOLDEN_ENCODED_FRAME_MISMATCH'
  | 'GOLDEN_MANIFEST_INVALID'
  | 'LIVE_VISUAL_CONTRACT_FAILED';

export class GoldenError extends Error {
  constructor(
    readonly code: GoldenErrorCode,
    message: string,
    readonly details?: Record<string, unknown>,
  ) {
    super(message);
    this.name = 'GoldenError';
  }
}

export interface ExactGoldenProfile {
  name: string;
  platform: NodeJS.Platform;
  architecture: string;
  osVersion: string;
  osBuild: string;
  nodeVersion: string;
  canvasVersion: string;
  nativeCanvasPackage: string;
  cursorSvgSha256: string;
  studioConstantsSha256: string;
}

export interface GoldenFrameRecord {
  purpose: string;
  outputIndex: number;
  outputTimestampMs: number;
  sourceIndex: number;
  sourceTimestampMs: number;
  sourceFile: string;
  file: string;
  pngSha256: string;
  rgbaSha256: string;
  camera: Pick<CameraFrameState, 'segmentId' | 'phase' | 'zoom' | 'centerCssX' | 'centerCssY'>;
  cursor: Pick<CursorFrameState, 'visible' | 'interpolation'> & {
    screenHotspotX?: number;
    screenHotspotY?: number;
  };
  ripples: Array<Pick<ClickRippleFrameState, 'clickId' | 'progress' | 'radius' | 'opacity'>>;
  output: { width: 1920; height: 1080; opaque: true };
}

export interface ExactGoldenManifest {
  schemaVersion: 1;
  authority: 'exact-synthetic-compositor';
  profile: ExactGoldenProfile;
  canonicalInputs: Record<string, string>;
  frames: GoldenFrameRecord[];
  structuralAssertions: Record<string, boolean>;
}

export interface PixelDifferenceStatistics {
  differingPixels: number;
  totalPixels: number;
  differingFraction: number;
  absoluteError: {
    redMean: number;
    greenMean: number;
    blueMean: number;
    alphaMean: number;
    maximumChannelError: number;
  };
  boundingBox?: Rect;
}
