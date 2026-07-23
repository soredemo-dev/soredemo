import { defineCommand } from 'citty';
import { applyProjectBootstrap, planProjectBootstrap } from '../../project/bootstrap.js';
import { CliExitError, EXIT_USAGE } from '../exit-codes.js';

export default defineCommand({
  meta: { name: 'init', description: 'Add safe Soredemo starter files to a project' },
  args: {
    directory: {
      type: 'positional',
      description: 'project directory',
      default: '.',
    },
    'dry-run': {
      type: 'boolean',
      description: 'show the file plan without writing',
      default: false,
    },
    yes: {
      type: 'boolean',
      description: 'apply without an interactive confirmation',
      default: false,
    },
    json: {
      type: 'boolean',
      description: 'write one JSON result',
      default: false,
    },
  },
  async run({ args }) {
    if (!args['dry-run'] && !args.yes) {
      process.stderr.write('Review with --dry-run, then pass --yes to create files.\n');
      throw new CliExitError(EXIT_USAGE);
    }
    const plan = await planProjectBootstrap(args.directory);
    const conflicts = plan.files
      .filter((file) => file.status === 'exists')
      .map((file) => file.path);
    const created =
      args['dry-run'] || conflicts.length > 0 ? [] : await applyProjectBootstrap(plan);
    const result = {
      success: conflicts.length === 0,
      dryRun: args['dry-run'],
      projectRoot: plan.projectRoot,
      files: plan.files.map(({ path, status }) => ({ path, status })),
      created,
      conflicts,
    };
    if (args.json) process.stdout.write(`${JSON.stringify(result)}\n`);
    else {
      for (const file of result.files) process.stdout.write(`${file.status}: ${file.path}\n`);
      if (conflicts.length > 0) process.stderr.write('No files written because conflicts exist.\n');
    }
    if (conflicts.length > 0) throw new CliExitError(EXIT_USAGE);
  },
});
