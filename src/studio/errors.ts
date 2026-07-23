export type StudioErrorCode =
  | 'STUDIO_PROJECT_INVALID'
  | 'STUDIO_PORT_UNAVAILABLE'
  | 'STUDIO_AUTH_INVALID'
  | 'STUDIO_ORIGIN_REJECTED'
  | 'STUDIO_PATH_INVALID'
  | 'STUDIO_RUN_NOT_FOUND'
  | 'STUDIO_RUN_CONFLICT'
  | 'STUDIO_EVENT_SEQUENCE_INVALID'
  | 'STUDIO_ARTIFACT_NOT_FOUND'
  | 'STUDIO_START_FAILED'
  | 'AGENT_UNAVAILABLE'
  | 'AGENT_PERMISSION_REQUIRED'
  | 'AGENT_PROPOSAL_INVALID';

export class StudioError extends Error {
  constructor(
    readonly code: StudioErrorCode,
    message: string,
    readonly statusCode = 400,
  ) {
    super(message);
    this.name = 'StudioError';
  }
}
