import { readFileSync } from 'node:fs';
import { defineCommand, renderUsage, runCommand } from 'citty';
import {
  CliExitError,
  EXIT_FAILURE,
  EXIT_SUCCESS,
  EXIT_USAGE,
  type ExitCode,
} from './exit-codes.js';

function packageVersion(): string {
  const packageJson = JSON.parse(
    readFileSync(new URL('../../package.json', import.meta.url), 'utf8'),
  ) as { version: string };
  return packageJson.version;
}

export const program = defineCommand({
  meta: {
    name: 'soredemo',
    version: packageVersion(),
    description: 'Compile declarative Demo Plans into polished product-demo videos.',
  },
  subCommands: {
    validate: () => import('./commands/validate.js').then((module) => module.default),
    render: () => import('./commands/render.js').then((module) => module.default),
  },
});

function isCittyUsageError(error: unknown): error is Error & { code: string } {
  return error instanceof Error && error.name === 'CLIError' && 'code' in error;
}

function rawArgumentError(argv: string[]): string | null {
  const command = argv[0];
  if (command !== 'validate' && command !== 'render') return null;

  const valueOptions = command === 'validate' ? new Set(['--format']) : new Set(['--out']);
  const booleanOptions = new Set(['--verbose']);
  let positionalCount = 0;

  for (let index = 1; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === undefined) continue;
    if (!argument.startsWith('-')) {
      positionalCount += 1;
      continue;
    }

    const option = argument.split('=', 1)[0];
    if (option && valueOptions.has(option)) {
      if (!argument.includes('=')) index += 1;
      continue;
    }
    if (option && booleanOptions.has(option)) continue;
    return `Unknown option: ${option ?? argument}`;
  }

  return positionalCount > 1 ? `Too many positional arguments for ${command}` : null;
}

export async function runCli(argv: string[]): Promise<ExitCode> {
  if (argv.includes('--help') || argv.includes('-h')) {
    process.stdout.write(`${await renderUsage(program)}\n`);
    return EXIT_SUCCESS;
  }

  if (argv.length === 1 && (argv[0] === '--version' || argv[0] === '-v')) {
    process.stdout.write(`${packageVersion()}\n`);
    return EXIT_SUCCESS;
  }

  const argumentError = rawArgumentError(argv);
  if (argumentError) {
    process.stderr.write(`${argumentError}\n`);
    process.stderr.write('Run `soredemo --help` for usage.\n');
    return EXIT_USAGE;
  }

  try {
    await runCommand(program, { rawArgs: argv });
    return EXIT_SUCCESS;
  } catch (error) {
    if (error instanceof CliExitError) return error.exitCode;
    if (isCittyUsageError(error)) {
      process.stderr.write(`${error.message}\n`);
      process.stderr.write('Run `soredemo --help` for usage.\n');
      return EXIT_USAGE;
    }

    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`Unexpected internal error: ${message}\n`);
    return EXIT_FAILURE;
  }
}
