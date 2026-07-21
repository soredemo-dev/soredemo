import type { RenderError, RenderStage, RenderWarning } from '../../render/errors.js';
import { publicRenderError } from '../../render/errors.js';

export type ReporterMode = 'human' | 'quiet' | 'verbose' | 'json';

export interface ReporterStageEvent {
  stage: RenderStage;
  status: 'completed';
  message: string;
  details?: Record<string, unknown>;
}

export class RenderReporter {
  constructor(readonly mode: ReporterMode) {}

  stage(event: ReporterStageEvent): void {
    if (this.mode === 'json') {
      process.stderr.write(`[${event.stage}] ${event.message}\n`);
      return;
    }
    if (this.mode === 'quiet') return;
    process.stderr.write(`✓ ${event.message}\n`);
    if (this.mode === 'verbose' && event.details) {
      process.stderr.write(`${JSON.stringify(event.details)}\n`);
    }
  }

  diagnostic(message: string, details?: Record<string, unknown>): void {
    if (this.mode !== 'verbose') return;
    process.stderr.write(`${message}${details ? ` ${JSON.stringify(details)}` : ''}\n`);
  }

  warning(warning: RenderWarning): void {
    if (this.mode === 'json') return;
    process.stderr.write(`Warning [${warning.code}]: ${warning.message}\n`);
  }

  success<T extends { outputPath: string; artifactsPath?: string }>(result: T): void {
    if (this.mode === 'json') {
      process.stdout.write(`${JSON.stringify(result)}\n`);
      return;
    }
    process.stdout.write(`Created ${String(result.outputPath)}\n`);
    if (typeof result.artifactsPath === 'string') {
      process.stdout.write(`Preserved artifacts: ${result.artifactsPath}\n`);
    }
  }

  failure(error: RenderError): void {
    if (this.mode === 'json') {
      process.stdout.write(`${JSON.stringify(publicRenderError(error))}\n`);
      return;
    }
    const action =
      error.actionIndex === undefined
        ? ''
        : `Action ${error.actionIndex} (${error.actionKind ?? 'unknown'}) `;
    process.stderr.write(`${action}${error.message}\n`);
    if (error.targetDescription) process.stderr.write(`  ${error.targetDescription}\n`);
    if (error.artifactsPath) process.stderr.write(`Preserved artifacts: ${error.artifactsPath}\n`);
    if (this.mode === 'verbose' && error.details) {
      process.stderr.write(`${JSON.stringify(error.details)}\n`);
    }
  }
}

export function reporterMode(options: {
  quiet?: boolean;
  verbose?: boolean;
  json?: boolean;
}): ReporterMode {
  if (options.json) return 'json';
  if (options.quiet) return 'quiet';
  if (options.verbose) return 'verbose';
  return 'human';
}
