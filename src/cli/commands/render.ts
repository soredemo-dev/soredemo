import { defineCommand } from 'citty';
import { CliExitError, EXIT_FAILURE, EXIT_USAGE } from '../exit-codes.js';
import { reportPlanError } from '../output/plan-error.js';

function writeFailure(json: boolean, code: string, message: string, workspacePath?: string): void {
  if (json) {
    process.stdout.write(
      `${JSON.stringify({ success: false, error: { code, message, ...(workspacePath ? { workspacePath } : {}) } })}\n`,
    );
  } else {
    process.stderr.write(`${message}\n`);
    if (workspacePath) process.stderr.write(`Preserved artifacts: ${workspacePath}\n`);
  }
}

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
    keepArtifacts: {
      type: 'boolean',
      description: 'preserve the temporary render workspace',
      default: false,
    },
    json: {
      type: 'boolean',
      description: 'write the final result as JSON',
      default: false,
    },
    verbose: {
      type: 'boolean',
      description: 'write verbose diagnostics to stderr',
      default: false,
    },
  },
  async run({ args }) {
    let outputPath: string;
    try {
      process.stderr.write('Validating demo plan\n');
      const { loadDemoPlan } = await import('../../plan/load.js');
      const plan = await loadDemoPlan(args.script);
      const { prepareOutputPath } = await import('../../render/output-path.js');
      try {
        outputPath = await prepareOutputPath(args.script, args.out);
      } catch (error) {
        writeFailure(
          args.json,
          'OUTPUT_INVALID',
          error instanceof Error ? error.message : String(error),
        );
        throw new CliExitError(EXIT_USAGE);
      }
      const protocol = new URL(plan.initialUrl).protocol;
      if (protocol !== 'http:' && protocol !== 'https:') {
        writeFailure(args.json, 'PLAN_INVALID', 'Initial URL must use http or https');
        throw new CliExitError(EXIT_FAILURE);
      }
      const { loadProjectConfiguration } = await import('../../config/load.js');
      const configuration = await loadProjectConfiguration(args.script);

      // Heavy capture and rendering code is loaded only after plan and output validation succeed.
      const { renderDemo } = await import('../../render/render-demo.js');
      const result = await renderDemo({
        plan,
        planFile: args.script,
        configuration,
        outputPath,
        keepArtifacts: args.keepArtifacts,
        onStage: (message) => process.stderr.write(`${message}\n`),
      });
      if (args.json) {
        process.stdout.write(`${JSON.stringify(result)}\n`);
      } else {
        process.stdout.write(`Created ${result.outputPath}\n`);
        if (result.preservedArtifactsPath) {
          process.stdout.write(`Preserved artifacts: ${result.preservedArtifactsPath}\n`);
        }
      }
      if (args.verbose) {
        process.stderr.write(`${JSON.stringify(result.diagnostics)}\n`);
      }
    } catch (error) {
      if (error instanceof CliExitError) throw error;
      const planExit = reportPlanError(error, args.json ? 'json' : 'human');
      if (planExit !== null) throw new CliExitError(planExit);
      const candidate = error as { code?: unknown; workspacePath?: unknown; message?: unknown };
      const code = typeof candidate.code === 'string' ? candidate.code : 'RENDER_FAILED';
      const message = typeof candidate.message === 'string' ? candidate.message : String(error);
      const workspacePath =
        typeof candidate.workspacePath === 'string' ? candidate.workspacePath : undefined;
      writeFailure(args.json, code, message, workspacePath);
      throw new CliExitError(EXIT_FAILURE);
    }
  },
});
