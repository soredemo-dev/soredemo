import { randomUUID } from 'node:crypto';
import { rm } from 'node:fs/promises';
import type { ProjectConfiguration } from '../config/load.js';
import type { ActionPlan } from '../plan/normalized-plan.js';
import { writeProofBundle } from '../proof/write-proof.js';
import { normalizeRenderError } from '../render/errors.js';
import { type RenderDemoResult, renderDemo } from '../render/render-demo.js';
import { RunEventJournal } from './event-journal.js';
import type { RunEvent, RunInitiator, RunSnapshot, RunState } from './types.js';

const TRANSITIONS: Record<RunState, readonly RunState[]> = {
  created: ['validating', 'stopping'],
  validating: ['awaitingApproval', 'ready', 'failed', 'stopping'],
  awaitingApproval: ['ready', 'failed', 'stopping'],
  ready: ['starting', 'stopping'],
  starting: ['capturing', 'failed', 'stopping'],
  capturing: ['composing', 'failed', 'stopping'],
  composing: ['encoding', 'failed', 'stopping'],
  encoding: ['verifying', 'failed', 'stopping'],
  verifying: ['completed', 'failed', 'stopping'],
  completed: [],
  stopping: ['stopped', 'failed'],
  stopped: [],
  failed: [],
};

export function assertRunTransition(from: RunState, to: RunState): void {
  if (!TRANSITIONS[from].includes(to)) throw new Error(`Illegal run transition: ${from} -> ${to}`);
}

export interface StartRunRequest {
  plan: ActionPlan;
  planFile: string;
  configuration: ProjectConfiguration;
  outputPath: string;
  proofPath?: string;
  keepArtifacts?: boolean;
  initiator: RunInitiator;
  initiatorLabel?: string;
  validationStartedAt?: string;
  onStage?: Parameters<typeof renderDemo>[0]['onStage'];
  onDiagnostic?: Parameters<typeof renderDemo>[0]['onDiagnostic'];
}

interface ActiveRun {
  snapshot: RunSnapshot;
  journal: RunEventJournal;
  abort: AbortController;
  completion: Promise<RenderDemoResult>;
  lastPreviewAt: number;
}

export class RunCoordinator {
  private readonly runs = new Map<string, ActiveRun>();

  start(request: StartRunRequest): { runId: string; completion: Promise<RenderDemoResult> } {
    const runId = randomUUID();
    const journal = new RunEventJournal(runId);
    const snapshot: RunSnapshot = {
      schemaVersion: 1,
      runId,
      createdAt: new Date().toISOString(),
      initiator: request.initiator,
      ...(request.initiatorLabel ? { initiatorLabel: request.initiatorLabel.slice(0, 80) } : {}),
      planPath: request.planFile,
      outputPath: request.outputPath,
      ...(request.proofPath ? { proofPath: request.proofPath } : {}),
      state: 'created',
      completedActions: 0,
      totalActions: request.plan.actions.length,
      lastSequence: 0,
    };
    const active: ActiveRun = {
      snapshot,
      journal,
      abort: new AbortController(),
      completion: Promise.resolve(undefined as never),
      lastPreviewAt: -Infinity,
    };
    this.runs.set(runId, active);
    this.emit(active, 'run.created', { initiator: request.initiator });
    active.completion = this.execute(active, request);
    return { runId, completion: active.completion };
  }

  async stop(runId: string): Promise<{ stopped: boolean; state: RunState }> {
    const run = this.require(runId);
    if (
      run.snapshot.state === 'stopped' ||
      run.snapshot.state === 'failed' ||
      run.snapshot.state === 'completed'
    ) {
      return { stopped: run.snapshot.state === 'stopped', state: run.snapshot.state };
    }
    if (run.snapshot.state !== 'stopping') {
      this.transition(run, 'stopping');
      this.emit(run, 'run.stopping', {});
      run.abort.abort(new Error('Studio requested stop'));
    }
    await run.completion.catch(() => undefined);
    const state = this.get(runId).state;
    return { stopped: state === 'stopped', state };
  }

  get(runId: string): RunSnapshot {
    return structuredClone(this.require(runId).snapshot);
  }

  list(): RunSnapshot[] {
    return [...this.runs.values()].map((run) => structuredClone(run.snapshot));
  }

  eventsAfter(runId: string, sequence: number): RunEvent[] {
    return this.require(runId).journal.after(sequence);
  }

  subscribe(runId: string, listener: (event: RunEvent) => void): () => void {
    return this.require(runId).journal.subscribe(listener);
  }

  private async execute(active: ActiveRun, request: StartRunRequest): Promise<RenderDemoResult> {
    try {
      this.transition(active, 'validating');
      this.emit(active, 'run.validating', {});
      this.transition(active, 'ready');
      this.emit(active, 'run.ready', {});
      this.transition(active, 'starting');
      this.emit(active, 'run.started', {});
      this.emit(active, 'capture.started', {});
      const internalKeep = Boolean(request.keepArtifacts || request.proofPath);
      const result = await renderDemo({
        plan: request.plan,
        planFile: request.planFile,
        configuration: request.configuration,
        outputPath: request.outputPath,
        keepArtifacts: internalKeep,
        ...(request.validationStartedAt
          ? { validationStartedAt: request.validationStartedAt }
          : {}),
        onStage: (event) => {
          if (event.stage === 'resampling' && active.snapshot.state === 'capturing') {
            this.emit(active, 'capture.completed', event.details ?? {});
            this.transition(active, 'composing');
            this.emit(active, 'compose.started', {});
          } else if (event.stage === 'composing' && active.snapshot.state === 'composing') {
            this.emit(active, 'compose.completed', event.details ?? {});
            this.transition(active, 'encoding');
            this.emit(active, 'encode.started', {});
          } else if (event.stage === 'validating-output' && active.snapshot.state === 'encoding') {
            this.emit(active, 'encode.progress', { status: 'validating-output' });
            this.transition(active, 'verifying');
            this.emit(active, 'proof.updated', { status: 'collected' });
          } else if (event.stage === 'encoding') {
            this.emit(active, 'encode.completed', event.details ?? {});
          }
          request.onStage?.(
            internalKeep && !request.keepArtifacts && event.stage === 'cleaning-up'
              ? { ...event, message: 'Cleaned render workspace after proof serialization' }
              : event,
          );
        },
        ...(request.onDiagnostic ? { onDiagnostic: request.onDiagnostic } : {}),
        signal: active.abort.signal,
        onObservation: (event) => this.observe(active, event),
      });
      if (active.snapshot.state === 'stopping') {
        this.transition(active, 'stopped');
        this.emit(active, 'run.stopped', {});
        return result;
      }
      if (active.snapshot.state === 'capturing') this.transition(active, 'composing');
      if (active.snapshot.state === 'composing') this.transition(active, 'encoding');
      if (active.snapshot.state === 'encoding') this.transition(active, 'verifying');
      if (request.proofPath && result.artifactsPath) {
        const proof = await writeProofBundle({
          directory: request.proofPath,
          workspace: result.artifactsPath,
          planFile: request.planFile,
          ...(request.configuration.file ? { configFile: request.configuration.file } : {}),
          outputPath: result.outputPath,
        });
        active.snapshot.proof = proof;
        this.emit(active, 'proof.completed', proof);
        this.emit(active, 'artifact.created', { kind: 'proof', path: proof.path });
      }
      const publicResult = { ...result };
      if (!request.keepArtifacts) {
        delete publicResult.artifactsPath;
        delete publicResult.preservedArtifactsPath;
        publicResult.warnings = publicResult.warnings.filter(
          (warning) => warning.code !== 'WORKSPACE_PRESERVED',
        );
      }
      active.snapshot.result = publicResult;
      this.emit(active, 'artifact.created', { kind: 'mp4', path: result.outputPath });
      this.transition(active, 'completed');
      this.emit(active, 'run.completed', {
        outputPath: result.outputPath,
        proofPath: request.proofPath,
      });
      if (internalKeep && !request.keepArtifacts && result.artifactsPath) {
        await rm(result.artifactsPath, { recursive: true, force: true });
      }
      return active.snapshot.result;
    } catch (error) {
      if (active.snapshot.state === 'stopping' || active.abort.signal.aborted) {
        if (active.snapshot.state !== 'stopping') this.transition(active, 'stopping');
        this.transition(active, 'stopped');
        this.emit(active, 'run.stopped', {});
      } else {
        const normalized = normalizeRenderError(error, {
          code: 'INTERNAL_ERROR',
          stage: 'cleaning-up',
        });
        this.transition(active, 'failed');
        active.snapshot.error = {
          code: normalized.code,
          message: normalized.message,
          stage: normalized.stage,
        };
        this.emit(active, 'run.failed', active.snapshot.error);
      }
      throw error;
    }
  }

  private observe(
    active: ActiveRun,
    event: NonNullable<Parameters<typeof renderDemo>[0]['onObservation']> extends (
      event: infer E,
    ) => void
      ? E
      : never,
  ): void {
    if (event.type === 'capture.preview') {
      if (event.timestampMs - active.lastPreviewAt < 500) return;
      active.lastPreviewAt = event.timestampMs;
      this.emit(active, 'capture.preview', event, 'application-pixels', true);
      return;
    }
    if (event.type === 'action.started') {
      active.snapshot.currentAction = {
        index: event.actionIndex,
        kind: event.actionKind,
        ...(event.targetDescription ? { targetDescription: event.targetDescription } : {}),
      };
      this.emit(active, 'action.resolving', event);
      this.emit(active, 'action.started', event);
      return;
    }
    if (event.type === 'action.completed') {
      active.snapshot.completedActions = event.actionIndex + 1;
      this.emit(active, 'action.resolved', event);
      this.emit(active, 'action.completed', event);
      return;
    }
    if (event.type === 'action.failed') {
      this.emit(active, 'action.failed', event);
      return;
    }
    if (event.type === 'capture.pixelScale') {
      this.emit(active, 'capture.metrics', event);
      return;
    }
    this.emit(active, 'compose.progress', { status: 'cursor-evidence-collected' });
    this.emit(active, 'cursor.landing', event);
    this.emit(active, 'target.pixelProof', {
      measurements: event.measurements,
      failures: event.failures,
    });
  }

  private transition(run: ActiveRun, state: RunState): void {
    assertRunTransition(run.snapshot.state, state);
    run.snapshot.state = state;
  }

  private emit(
    run: ActiveRun,
    type: string,
    payload: Record<string, unknown>,
    privacy: RunEvent['privacy'] = 'project-metadata',
    ephemeral = false,
  ): void {
    const event = run.journal.publish(type, payload, privacy, { ephemeral });
    run.snapshot.lastSequence = event.sequence;
    if (type === 'run.started') this.transition(run, 'capturing');
  }

  private require(runId: string): ActiveRun {
    const run = this.runs.get(runId);
    if (!run) throw new Error('STUDIO_RUN_NOT_FOUND');
    return run;
  }
}
