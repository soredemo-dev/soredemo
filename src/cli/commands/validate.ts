import { resolve } from 'node:path';
import { defineCommand } from 'citty';
import { CliExitError, EXIT_SUCCESS, EXIT_USAGE } from '../exit-codes.js';
import { reportPlanError } from '../output/plan-error.js';

export default defineCommand({
  meta: {
    name: 'validate',
    description: 'Validate a YAML Demo Plan',
  },
  args: {
    script: {
      type: 'positional',
      description: 'path to a Demo Plan YAML file',
      required: true,
    },
    format: {
      type: 'enum',
      description: 'output format',
      options: ['human', 'json'],
      default: 'human',
    },
    json: {
      type: 'boolean',
      description: 'write JSON output',
      default: false,
    },
    quiet: {
      type: 'boolean',
      description: 'print only the final result or error',
      default: false,
    },
    verbose: {
      type: 'boolean',
      description: 'write verbose diagnostics to stderr',
      default: false,
    },
  },
  async run({ args }) {
    const json = args.json || args.format === 'json';
    if (Number(json) + Number(args.quiet) + Number(args.verbose) > 1) {
      process.stderr.write('Use only one of --quiet, --verbose, or JSON output.\n');
      throw new CliExitError(EXIT_USAGE);
    }
    try {
      const { loadDemoPlan } = await import('../../plan/load.js');
      const plan = await loadDemoPlan(args.script);

      if (json) {
        process.stdout.write(
          `${JSON.stringify({ valid: true, name: plan.name, file: resolve(args.script) })}\n`,
        );
      } else if (args.quiet) {
        process.stdout.write(`Valid demo plan: ${plan.name}\n`);
      } else {
        process.stdout.write(`✓ Validated demo plan: ${plan.name}\n`);
      }
      if (args.verbose) process.stderr.write(`Plan file: ${resolve(args.script)}\n`);
      return EXIT_SUCCESS;
    } catch (error) {
      const exitCode = reportPlanError(error, json ? 'json' : 'human');
      if (exitCode === null) throw error;
      throw new CliExitError(exitCode);
    }
  },
});
