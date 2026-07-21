import { describe, expect, it } from 'vitest';
import {
  normalizeRenderError,
  publicRenderError,
  RENDER_ERROR_CODES,
  RenderError,
} from '../../src/render/errors.js';

describe('stable render errors', () => {
  it('publishes the complete constrained private-alpha error code set', () => {
    expect(RENDER_ERROR_CODES).toEqual([
      'PLAN_INVALID',
      'CONFIG_INVALID',
      'OUTPUT_EXISTS',
      'OUTPUT_PATH_INVALID',
      'FFMPEG_NOT_FOUND',
      'FFPROBE_NOT_FOUND',
      'ENCODER_CAPABILITY_MISSING',
      'BROWSER_LAUNCH_FAILED',
      'NAVIGATION_FAILED',
      'TARGET_NOT_FOUND',
      'TARGET_AMBIGUOUS',
      'TARGET_NOT_VISIBLE',
      'TARGET_NOT_ENABLED',
      'ACTION_TIMEOUT',
      'ACTION_FAILED',
      'CAPTURE_FAILED',
      'CAPTURE_TIMESTAMP_INVALID',
      'CAPTURE_PIXEL_SCALE_INVALID',
      'RESAMPLE_FAILED',
      'COMPOSITION_FAILED',
      'CURSOR_SYNCHRONIZATION_FAILED',
      'ENCODE_FAILED',
      'OUTPUT_VALIDATION_FAILED',
      'RENDER_ABORTED',
      'INTERNAL_ERROR',
    ]);
  });

  it('normalizes legacy prefixes without exposing a stack', () => {
    const error = normalizeRenderError(new Error('TARGET_NOT_FOUND: missing'), {
      code: 'ACTION_FAILED',
      stage: 'capturing',
    });
    expect(publicRenderError(error)).toEqual({
      success: false,
      code: 'TARGET_NOT_FOUND',
      message: 'missing',
      stage: 'capturing',
    });
    expect(JSON.stringify(publicRenderError(error))).not.toContain('stack');
  });

  it('bounds public action metadata to explicit fields', () => {
    const error = new RenderError({
      code: 'TARGET_AMBIGUOUS',
      stage: 'capturing',
      message: 'Matched 3 elements',
      actionIndex: 4,
      actionKind: 'click',
      targetDescription: 'role=button, name="Create project"',
      artifactsPath: '/tmp/run',
      details: { candidates: [{ tagName: 'button' }] },
    });
    expect(publicRenderError(error)).toMatchObject({
      success: false,
      code: 'TARGET_AMBIGUOUS',
      actionIndex: 4,
      actionKind: 'click',
      artifactsPath: '/tmp/run',
    });
  });
});
