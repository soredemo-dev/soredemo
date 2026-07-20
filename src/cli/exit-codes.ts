export const EXIT_SUCCESS = 0;
export const EXIT_FAILURE = 1;
export const EXIT_USAGE = 2;

export type ExitCode = typeof EXIT_SUCCESS | typeof EXIT_FAILURE | typeof EXIT_USAGE;

export class CliExitError extends Error {
  constructor(readonly exitCode: ExitCode) {
    super(`CLI exited with status ${exitCode}`);
    this.name = 'CliExitError';
  }
}
