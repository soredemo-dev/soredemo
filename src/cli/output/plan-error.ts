import {
  DemoPlanFileError,
  DemoPlanSyntaxError,
  DemoPlanValidationError,
} from '../../plan/errors.js';
import { EXIT_FAILURE, EXIT_USAGE, type ExitCode } from '../exit-codes.js';
import { formatValidationHuman, formatValidationJson } from './validation.js';

export type OutputFormat = 'human' | 'json';

function formatSingleErrorJson(
  code: string,
  expected: string,
  received: string,
  message: string,
): string {
  return `${JSON.stringify(
    {
      valid: false,
      errors: [{ path: [], code, expected, received, message }],
    },
    null,
    2,
  )}\n`;
}

export function reportPlanError(error: unknown, format: OutputFormat): ExitCode | null {
  if (error instanceof DemoPlanValidationError) {
    const output = format === 'json' ? formatValidationJson(error) : formatValidationHuman(error);
    (format === 'json' ? process.stdout : process.stderr).write(output);
    return EXIT_FAILURE;
  }

  if (error instanceof DemoPlanSyntaxError) {
    const output =
      format === 'json'
        ? formatSingleErrorJson(error.code, 'valid YAML', 'invalid syntax', error.message)
        : `${error.message}\n`;
    (format === 'json' ? process.stdout : process.stderr).write(output);
    return EXIT_FAILURE;
  }

  if (error instanceof DemoPlanFileError) {
    const output =
      format === 'json'
        ? formatSingleErrorJson(error.code, 'readable file', 'unavailable', error.message)
        : `${error.message}\n`;
    (format === 'json' ? process.stdout : process.stderr).write(output);
    return EXIT_USAGE;
  }

  return null;
}
