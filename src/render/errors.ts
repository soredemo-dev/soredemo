export type RenderErrorCode =
  | 'PLAN_INVALID'
  | 'CONFIG_INVALID'
  | 'OUTPUT_EXISTS'
  | 'OUTPUT_PATH_INVALID'
  | 'FFMPEG_NOT_FOUND'
  | 'FFPROBE_NOT_FOUND'
  | 'ENCODER_CAPABILITY_MISSING'
  | 'CHROMIUM_NOT_INSTALLED'
  | 'BROWSER_LAUNCH_FAILED'
  | 'NAVIGATION_FAILED'
  | 'TARGET_NOT_FOUND'
  | 'TARGET_AMBIGUOUS'
  | 'TARGET_NOT_VISIBLE'
  | 'TARGET_NOT_ENABLED'
  | 'ACTION_TIMEOUT'
  | 'ACTION_FAILED'
  | 'CAPTURE_FAILED'
  | 'CAPTURE_TIMESTAMP_INVALID'
  | 'CAPTURE_PIXEL_SCALE_INVALID'
  | 'RESAMPLE_FAILED'
  | 'COMPOSITION_FAILED'
  | 'CURSOR_SYNCHRONIZATION_FAILED'
  | 'ENCODE_FAILED'
  | 'OUTPUT_VALIDATION_FAILED'
  | 'RENDER_ABORTED'
  | 'INTERNAL_ERROR';

export type RenderStage =
  | 'validating'
  | 'preflight'
  | 'launching-browser'
  | 'preparing-page'
  | 'capturing'
  | 'resampling'
  | 'composing'
  | 'encoding'
  | 'validating-output'
  | 'publishing-output'
  | 'cleaning-up';

export type RenderWarningCode =
  | 'SLOW_COMPOSITION'
  | 'HIGH_PARENT_MEMORY'
  | 'HIGH_ENCODER_MEMORY'
  | 'CDP_EXPERIMENTAL_SURFACE'
  | 'SYSTEM_FFMPEG_GPL_BUILD'
  | 'CAPTURE_VERSION_SENSITIVE'
  | 'WORKSPACE_PRESERVED';

export interface RenderWarning {
  code: RenderWarningCode;
  message: string;
}

export interface RenderErrorOptions extends ErrorOptions {
  code: RenderErrorCode;
  message: string;
  stage: RenderStage;
  actionIndex?: number;
  actionKind?: string;
  targetDescription?: string;
  artifactsPath?: string;
  details?: Record<string, unknown>;
}

const ERROR_PREFIX = /\b([A-Z][A-Z0-9_]+):\s*/;

export class RenderError extends Error {
  readonly code: RenderErrorCode;
  readonly stage: RenderStage;
  readonly actionIndex: number | undefined;
  readonly actionKind: string | undefined;
  readonly targetDescription: string | undefined;
  readonly artifactsPath: string | undefined;
  readonly details: Record<string, unknown> | undefined;

  constructor(options: RenderErrorOptions) {
    super(options.message, { cause: options.cause });
    this.name = 'RenderError';
    this.code = options.code;
    this.stage = options.stage;
    this.actionIndex = options.actionIndex;
    this.actionKind = options.actionKind;
    this.targetDescription = options.targetDescription;
    this.artifactsPath = options.artifactsPath;
    this.details = options.details;
  }

  withArtifactsPath(artifactsPath: string): RenderError {
    return new RenderError({
      code: this.code,
      message: this.message,
      stage: this.stage,
      ...(this.actionIndex === undefined ? {} : { actionIndex: this.actionIndex }),
      ...(this.actionKind === undefined ? {} : { actionKind: this.actionKind }),
      ...(this.targetDescription === undefined
        ? {}
        : { targetDescription: this.targetDescription }),
      artifactsPath,
      ...(this.details === undefined ? {} : { details: this.details }),
      cause: this.cause,
    });
  }
}

export function isRenderError(error: unknown): error is RenderError {
  return error instanceof RenderError;
}

export function renderError(options: RenderErrorOptions): RenderError {
  return new RenderError(options);
}

export function normalizeRenderError(
  error: unknown,
  fallback: { code: RenderErrorCode; stage: RenderStage; message?: string },
): RenderError {
  if (isRenderError(error)) return error;
  const rawMessage = error instanceof Error ? error.message : String(error);
  const match = rawMessage.match(ERROR_PREFIX)?.[1];
  const code = isRenderErrorCode(match) ? match : fallback.code;
  const message = rawMessage.replace(ERROR_PREFIX, '').slice(0, 1000) || fallback.message || code;
  return new RenderError({
    code,
    stage: fallback.stage,
    message,
    cause: error,
  });
}

export function isRenderErrorCode(value: unknown): value is RenderErrorCode {
  return typeof value === 'string' && RENDER_ERROR_CODES.includes(value as RenderErrorCode);
}

export const RENDER_ERROR_CODES: readonly RenderErrorCode[] = [
  'PLAN_INVALID',
  'CONFIG_INVALID',
  'OUTPUT_EXISTS',
  'OUTPUT_PATH_INVALID',
  'FFMPEG_NOT_FOUND',
  'FFPROBE_NOT_FOUND',
  'ENCODER_CAPABILITY_MISSING',
  'CHROMIUM_NOT_INSTALLED',
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
];

export function publicRenderError(error: RenderError): Record<string, unknown> {
  return {
    success: false,
    code: error.code,
    message: error.message,
    stage: error.stage,
    ...(error.actionIndex === undefined ? {} : { actionIndex: error.actionIndex }),
    ...(error.actionKind === undefined ? {} : { actionKind: error.actionKind }),
    ...(error.targetDescription === undefined
      ? {}
      : { targetDescription: error.targetDescription }),
    ...(error.artifactsPath === undefined ? {} : { artifactsPath: error.artifactsPath }),
    ...(error.details === undefined ? {} : { details: error.details }),
  };
}
