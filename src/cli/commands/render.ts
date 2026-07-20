import { defineCommand } from 'citty';
import { CliExitError, EXIT_FAILURE } from '../exit-codes.js';
import { reportPlanError } from '../output/plan-error.js';

export default defineCommand({
  meta: {
    name: 'render',
    description: 'Render a Demo Plan to MP4',
  },
  args: {
    script: {
      type: 'positional',
      description: 'path to a Demo Plan YAML file',
      required: true,
    },
    out: {
      type: 'string',
      description: 'output MP4 path',
      valueHint: 'file',
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
      if (args.verbose) {
        process.stderr.write(`Loaded ${plan.name} from ${args.script}\n`);
        if (args.out) process.stderr.write(`Requested output: ${args.out}\n`);
      }
      process.stderr.write(
        'Capture and rendering are not implemented on Day 1; they are scheduled for later phases.\n',
      );
      throw new CliExitError(EXIT_FAILURE);
    } catch (error) {
      if (error instanceof CliExitError) throw error;
      const exitCode = reportPlanError(error, 'human');
      if (exitCode === null) throw error;
      throw new CliExitError(exitCode);
    }
  },
});
