import { defineCommand } from 'citty';
import type { ProjectConfiguration } from '../../config/load.js';
import {
  DemoPlanFileError,
  DemoPlanSyntaxError,
  DemoPlanValidationError,
} from '../../plan/errors.js';
import type { ActionPlan } from '../../plan/normalized-plan.js';
import { normalizeRenderError, RenderError, type RenderErrorCode } from '../../render/errors.js';
import { CliExitError, EXIT_FAILURE, EXIT_USAGE } from '../exit-codes.js';
import { RenderReporter, reporterMode } from '../output/render-reporter.js';

function incompatibleFlags(args: { quiet: boolean; verbose: boolean; json: boolean }): boolean {
  return Number(args.quiet) + Number(args.verbose) + Number(args.json) > 1;
}

function planError(error: unknown): RenderError | null {
  if (error instanceof DemoPlanValidationError || error instanceof DemoPlanSyntaxError) {
    return new RenderError({
      code: 'PLAN_INVALID',
      stage: 'validating',
      message: error.message,
      details:
        error instanceof DemoPlanValidationError
          ? {
              errors: error.issues.slice(0, 20).map((issue) => ({
                path: issue.path,
                code: issue.code,
                message: issue.message,
              })),
            }
          : { sourceCode: error.code },
      cause: error,
    });
  }
  if (error instanceof DemoPlanFileError) {
    return new RenderError({
      code: 'PLAN_INVALID',
      stage: 'validating',
      message: error.message,
      cause: error,
    });
  }
  return null;
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
    proof: {
      type: 'string',
      description: 'write a portable proof bundle',
      valueHint: 'directory',
    },
    'keep-artifacts': {
      type: 'boolean',
      description: 'preserve the temporary render workspace',
      default: false,
    },
    quiet: {
      type: 'boolean',
      description: 'print only final results, warnings, and errors',
      default: false,
    },
    json: {
      type: 'boolean',
      description: 'write exactly one JSON result to stdout',
      default: false,
    },
    verbose: {
      type: 'boolean',
      description: 'write detailed diagnostics to stderr',
      default: false,
    },
  },
  async run({ args }) {
    if (incompatibleFlags(args)) {
      process.stderr.write('Use only one of --quiet, --verbose, or --json.\n');
      throw new CliExitError(EXIT_USAGE);
    }
    const reporter = new RenderReporter(reporterMode(args));
    try {
      const validationStartedAt = new Date().toISOString();
      let plan: ActionPlan;
      try {
        const { loadDemoPlan } = await import('../../plan/load.js');
        plan = await loadDemoPlan(args.script);
      } catch (error) {
        throw planError(error) ?? error;
      }
      const { prepareOutputPath } = await import('../../render/output-path.js');
      const outputPath = await prepareOutputPath(args.script, args.out);
      let protocol: string;
      try {
        protocol = new URL(plan.initialUrl).protocol;
      } catch (error) {
        throw new RenderError({
          code: 'PLAN_INVALID',
          stage: 'validating',
          message: 'Initial URL is invalid',
          cause: error,
        });
      }
      if (protocol !== 'http:' && protocol !== 'https:') {
        throw new RenderError({
          code: 'PLAN_INVALID',
          stage: 'validating',
          message: 'Initial URL must use http or https',
        });
      }
      const { loadProjectConfiguration } = await import('../../config/load.js');
      let configuration: ProjectConfiguration;
      try {
        configuration = await loadProjectConfiguration(args.script);
      } catch (error) {
        throw normalizeRenderError(error, { code: 'CONFIG_INVALID', stage: 'validating' });
      }
      // Heavy rendering code is loaded only after the plan, configuration, and output validate.
      const proofPath = args.proof
        ? await (await import('../../proof/output-path.js')).prepareProofPath(args.proof)
        : undefined;
      const { RunCoordinator } = await import('../../run-service/run-coordinator.js');
      const coordinator = new RunCoordinator();
      const started = coordinator.start({
        plan,
        planFile: args.script,
        configuration,
        outputPath,
        ...(proofPath ? { proofPath } : {}),
        keepArtifacts: args['keep-artifacts'],
        initiator: 'cli',
        validationStartedAt,
        onStage: (event) => reporter.stage(event),
        onDiagnostic: (message, details) => reporter.diagnostic(message, details),
      });
      const result = await started.completion;
      for (const warning of result.warnings) reporter.warning(warning);
      reporter.success(result);
    } catch (error) {
      const normalized = normalizeRenderError(error, {
        code: 'INTERNAL_ERROR' satisfies RenderErrorCode,
        stage: 'validating',
        message: 'Unexpected render failure',
      });
      reporter.failure(normalized);
      throw new CliExitError(
        normalized.code === 'OUTPUT_EXISTS' || normalized.code === 'OUTPUT_PATH_INVALID'
          ? EXIT_USAGE
          : EXIT_FAILURE,
      );
    }
  },
});
