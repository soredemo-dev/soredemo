import type { RenderDemoResult } from '../render/render-demo.js';

export type RunState =
  | 'created'
  | 'validating'
  | 'awaitingApproval'
  | 'ready'
  | 'starting'
  | 'capturing'
  | 'composing'
  | 'encoding'
  | 'verifying'
  | 'completed'
  | 'stopping'
  | 'stopped'
  | 'failed';

export type RunInitiator = 'cli' | 'studio' | 'agent';

export interface RunEvent {
  schemaVersion: 1;
  eventId: string;
  runId: string;
  sequence: number;
  type: string;
  producerTimestampMs: number;
  privacy: 'public' | 'project-metadata' | 'application-pixels' | 'sensitive-local';
  payload: Record<string, unknown>;
}

export interface RunSnapshot {
  schemaVersion: 1;
  runId: string;
  createdAt: string;
  initiator: RunInitiator;
  initiatorLabel?: string;
  planPath: string;
  outputPath: string;
  proofPath?: string;
  state: RunState;
  currentAction?: { index: number; kind: string; targetDescription?: string };
  completedActions: number;
  totalActions: number;
  lastSequence: number;
  result?: RenderDemoResult;
  proof?: { path: string; level: string; manifestSha256: string };
  error?: { code: string; message: string; stage?: string };
}
