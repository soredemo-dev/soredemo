import type { ZodIssue } from 'zod';

export class DemoPlanFileError extends Error {
  readonly code = 'file_error';

  constructor(
    message: string,
    readonly cause?: unknown,
  ) {
    super(message);
    this.name = 'DemoPlanFileError';
  }
}

export class DemoPlanSyntaxError extends Error {
  readonly code = 'yaml_syntax_error';

  constructor(
    message: string,
    readonly cause?: unknown,
  ) {
    super(message);
    this.name = 'DemoPlanSyntaxError';
  }
}

export class DemoPlanValidationError extends Error {
  readonly code = 'validation_error';

  constructor(
    readonly issues: ZodIssue[],
    readonly input: unknown,
  ) {
    super('Invalid demo plan');
    this.name = 'DemoPlanValidationError';
  }
}
