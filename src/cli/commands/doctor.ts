import { defineCommand } from 'citty';
import { CliExitError, EXIT_FAILURE, EXIT_SUCCESS, EXIT_USAGE } from '../exit-codes.js';

export default defineCommand({
  meta: { name: 'doctor', description: 'Check local rendering prerequisites' },
  args: {
    json: { type: 'boolean', description: 'write JSON output', default: false },
    quiet: { type: 'boolean', description: 'print only failures and final status', default: false },
    verbose: { type: 'boolean', description: 'write detailed diagnostics', default: false },
    deep: {
      type: 'boolean',
      description: 'reserved for a future live Chromium capture check',
      default: false,
    },
  },
  async run({ args }) {
    if (args.deep) {
      process.stderr.write('doctor --deep is not implemented in Day 11.\n');
      throw new CliExitError(EXIT_USAGE);
    }
    if (Number(args.json) + Number(args.quiet) + Number(args.verbose) > 1) {
      process.stderr.write('Use only one of --quiet, --verbose, or --json.\n');
      throw new CliExitError(EXIT_USAGE);
    }
    const { runDoctor } = await import('../../doctor/run-doctor.js');
    const result = await runDoctor();
    if (args.json) {
      process.stdout.write(`${JSON.stringify(result)}\n`);
    } else {
      for (const check of result.checks) {
        if (!args.quiet || !check.available) {
          process.stdout.write(`${check.available ? '✓' : '✗'} ${check.summary}\n`);
        }
        if (args.verbose && check.details)
          process.stderr.write(`${JSON.stringify(check.details)}\n`);
      }
      for (const warning of result.warnings) {
        if (!args.quiet) process.stderr.write(`Warning [${warning.code}]: ${warning.message}\n`);
      }
      process.stdout.write(
        result.success ? 'Soredemo is ready to render.\n' : 'Soredemo is not ready.\n',
      );
    }
    if (!result.success) throw new CliExitError(EXIT_FAILURE);
    return EXIT_SUCCESS;
  },
});
