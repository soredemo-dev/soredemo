import { z } from 'zod';
import { ScriptInputSchema } from '../plan/input-schema.js';

const NonEmpty = z.string().min(1).max(2_000);

export const ProposedDemoSchema = z.strictObject({
  schemaVersion: z.literal(1).default(1),
  title: NonEmpty,
  summary: NonEmpty,
  assumptions: z.array(NonEmpty).max(20),
  estimatedDurationMs: z.number().int().positive().optional(),
  plan: ScriptInputSchema,
  unresolved: z
    .array(
      z.strictObject({
        code: NonEmpty,
        message: NonEmpty,
        actionIndex: z.number().int().nonnegative().optional(),
        candidates: z.array(NonEmpty).max(20).optional(),
      }),
    )
    .max(50),
  warnings: z.array(NonEmpty).max(50),
});

export type ProposedDemo = z.infer<typeof ProposedDemoSchema>;

export interface AgentAvailability {
  available: boolean;
  version?: string;
  reason?: string;
  capabilities: string[];
}

export interface AgentPrivacyConsent {
  sourceFiles: boolean;
  semanticSnapshot: boolean;
  existingPlansAndTests: boolean;
  screenshots: false;
}

export interface SemanticApplicationSnapshot {
  schemaVersion: 1;
  url: string;
  title: string;
  viewport: { width: number; height: number };
  elements: Array<{
    tag: string;
    role?: string;
    name?: string;
    label?: string;
    testId?: string;
    rect: { x: number; y: number; width: number; height: number };
  }>;
  visibleTextSummary: string;
  truncated: boolean;
}

export interface ProposeDemoPlanRequest {
  conversationId: string;
  featureRequest: string;
  projectRoot: string;
  initialUrl: string;
  consent: AgentPrivacyConsent;
  snapshot?: SemanticApplicationSnapshot;
  sourceContext?: Array<{ path: string; content: string; truncated: boolean }>;
  previousProposal?: ProposedDemo;
  revisionRequest?: string;
}

export type AgentEvent =
  | { type: 'agent.started'; conversationId: string }
  | { type: 'agent.progress'; message: string }
  | { type: 'agent.proposal'; proposal: ProposedDemo; sessionId?: string }
  | { type: 'agent.failed'; message: string };

export interface AgentProvider {
  readonly id: string;
  readonly displayName: string;
  checkAvailability(): Promise<AgentAvailability>;
  proposePlan(request: ProposeDemoPlanRequest): AsyncIterable<AgentEvent>;
  revisePlan(request: ProposeDemoPlanRequest): AsyncIterable<AgentEvent>;
  cancel(conversationId: string): Promise<void>;
}
