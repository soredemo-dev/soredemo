import type { BBox } from '../timeline/types.js';
import type { Rect } from './types.js';

export interface Size {
  width: number;
  height: number;
}

export interface CssRect extends Rect {}

export interface CameraState {
  zoom: number;
  centerCssX: number;
  centerCssY: number;
}

export interface CameraTransitionSegment {
  id: string;
  phase: 'transition';
  clickId: string;
  startMs: number;
  endMs: number;
  from: CameraState;
  to: CameraState;
  compressed: boolean;
}

export interface CameraHoldSegment {
  id: string;
  phase: 'establish' | 'hold';
  startMs: number;
  endMs: number;
  state: CameraState;
  clickId?: string;
}

export type CameraSegment = CameraTransitionSegment | CameraHoldSegment;

export interface CameraTrack {
  durationMs: number;
  viewport: Size;
  segments: CameraSegment[];
  transitions: CameraTransitionSegment[];
}

export interface CameraFrameState extends CameraState {
  outputTimestampMs: number;
  segmentId: string;
  phase: 'establish' | 'transition' | 'hold';
  linearProgress?: number;
  easedProgress?: number;
  visibleCssRect: CssRect;
}

export interface SourceCrop extends Rect {}

export interface TargetFramingMeasurement {
  clickId: string;
  targetTestId: string;
  outputIndex: number;
  zoom: number;
  cameraCenterCssX: number;
  cameraCenterCssY: number;
  targetOutputRect: Rect;
  visibleFraction: number;
  clickPointInsideProjectedTarget: boolean;
  targetCenterDistanceFromContentCenterPx: number;
}

export interface CameraFocusInput {
  clickId: string;
  target: BBox;
}
