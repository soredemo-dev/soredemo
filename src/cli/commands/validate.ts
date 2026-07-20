import { defineCommand } from 'citty';
import { CliExitError, EXIT_SUCCESS } from '../exit-codes.js';
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
    verbose: {
      type: 'boolean',
      description: 'write verbose diagnostics to stderr',
      default: false,
    },
  },
  async run({ args }) {
    try {
      const { loadDemoPlan } = await import('../../plan/load.js');
      const plan = await loadDemoPlan(args.script);

      if (args.format === 'json') {
        process.stdout.write(`${JSON.stringify({ valid: true })}\n`);
      } else {
        process.stdout.write(`Valid demo plan: ${plan.name}\n`);
      }
      if (args.verbose) process.stderr.write(`Validated ${args.script}\n`);
      return EXIT_SUCCESS;
    } catch (error) {
      const exitCode = reportPlanError(error, args.format === 'json' ? 'json' : 'human');
      if (exitCode === null) throw error;
      throw new CliExitError(exitCode);
    }
  },
});
