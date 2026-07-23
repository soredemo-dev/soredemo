import { defineCommand, renderUsage, runCommand } from 'citty';
import {
  CliExitError,
  EXIT_FAILURE,
  EXIT_SUCCESS,
  EXIT_USAGE,
  type ExitCode,
} from './exit-codes.js';
import { packageMetadata } from './package-metadata.js';

const metadata = packageMetadata();
const DESCRIPTION = 'Turn declarative YAML into polished product demos of real web apps.';

export const program = defineCommand({
  meta: {
    name: 'soredemo',
    version: metadata.version,
    description: DESCRIPTION,
  },
  subCommands: {
    validate: () => import('./commands/validate.js').then((module) => module.default),
    render: () => import('./commands/render.js').then((module) => module.default),
    doctor: () => import('./commands/doctor.js').then((module) => module.default),
    init: () => import('./commands/init.js').then((module) => module.default),
    studio: () => import('./commands/studio.js').then((module) => module.default),
    proof: () => import('./commands/proof.js').then((module) => module.default),
  },
});

function isCittyUsageError(error: unknown): error is Error & { code: string } {
  return error instanceof Error && error.name === 'CLIError' && 'code' in error;
}

function rawArgumentError(argv: string[]): string | null {
  const command = argv[0];
  if (
    command !== 'validate' &&
    command !== 'render' &&
    command !== 'doctor' &&
    command !== 'init' &&
    command !== 'studio' &&
    command !== 'proof'
  )
    return null;

  const valueOptions =
    command === 'validate'
      ? new Set(['--format'])
      : command === 'render'
        ? new Set(['--out', '--proof'])
        : command === 'studio'
          ? new Set(['--project', '--host', '--port', '--agent'])
          : new Set();
  const booleanOptions = new Set([
    '--verbose',
    '--quiet',
    '--keep-artifacts',
    '--json',
    '--deep',
    '--dry-run',
    '--yes',
    '--no-open',
  ]);
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

  if ((command === 'doctor' || command === 'studio') && positionalCount > 0)
    return `${command} does not accept a positional argument`;
  if (command === 'proof')
    return positionalCount > 2 ? 'Too many positional arguments for proof' : null;
  return positionalCount > 1 ? `Too many positional arguments for ${command}` : null;
}

export async function runCli(argv: string[]): Promise<ExitCode> {
  if (argv.length === 0 || (argv.length === 1 && (argv[0] === '--help' || argv[0] === '-h'))) {
    process.stdout.write(
      `Soredemo public alpha — ${DESCRIPTION}\n\n${await renderUsage(program)}\n\nWorkflow:\n  soredemo doctor\n  soredemo validate demos/create-project.yaml\n  soredemo render demos/create-project.yaml --out output/create-project.mp4\n\nDocumentation: https://github.com/soredemo-dev/soredemo#readme\n`,
    );
    return EXIT_SUCCESS;
  }

  if (argv.length === 1 && (argv[0] === '--version' || argv[0] === '-v')) {
    process.stdout.write(`${metadata.version}\n`);
    return EXIT_SUCCESS;
  }

  if (
    argv.length === 2 &&
    (argv[1] === '--help' || argv[1] === '-h') &&
    ['validate', 'render', 'doctor', 'init', 'studio', 'proof'].includes(argv[0] ?? '')
  ) {
    const loader =
      argv[0] === 'validate'
        ? () => import('./commands/validate.js')
        : argv[0] === 'render'
          ? () => import('./commands/render.js')
          : argv[0] === 'doctor'
            ? () => import('./commands/doctor.js')
            : argv[0] === 'init'
              ? () => import('./commands/init.js')
              : argv[0] === 'studio'
                ? () => import('./commands/studio.js')
                : () => import('./commands/proof.js');
    const command = await loader();
    const usage = await renderUsage(command.default as never);
    process.stdout.write(`${usage}\n`);
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
