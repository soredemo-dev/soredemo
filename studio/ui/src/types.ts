export interface AgentInfo {
  id: string;
  displayName: string;
  available: boolean;
  version?: string;
  reason?: string;
}

export interface Meta {
  product: string;
  version: string;
  localOnly: boolean;
  projectRoot: string;
  agent: AgentInfo;
  proofPixelMode: boolean;
}

export interface PlanAction {
  action: 'goto' | 'wait' | 'moveTo' | 'click' | 'type' | 'scrollTo';
  target?: unknown;
  textLength?: number;
  [key: string]: unknown;
}

export interface DiscoveredAction {
  ordinal: number;
  kind: string;
  target?: string;
  textLength?: number;
}

export interface PlanRecord {
  path: string;
  valid: boolean;
  name?: string;
  url?: string;
  actions?: DiscoveredAction[];
  actionCount?: number;
  error?: string;
}

export interface Proposal {
  schemaVersion: number;
  title: string;
  summary: string;
  assumptions: string[];
  plan: { actions: PlanAction[]; [key: string]: unknown };
  unresolved: string[];
  warnings: string[];
}

export interface RunEvent {
  type: string;
  sequence: number;
  payload: Record<string, unknown>;
  privacy?: string;
}

export type StepState = 'pending' | 'resolving' | 'active' | 'completed' | 'failed';

export interface StepView {
  index: number;
  action: string;
  target: string;
  state: StepState;
  errorCode?: string;
  errorMessage?: string;
  cursorVerified?: boolean;
  pixelsVerified?: boolean;
}

export type RunPhase =
  | 'idle'
  | 'validating'
  | 'ready'
  | 'running'
  | 'capturing'
  | 'composing'
  | 'encoding'
  | 'completed'
  | 'failed'
  | 'stopped';

export interface Evidence {
  captureScale?: 'passed' | 'failed';
  cursorLanding?: 'passed' | 'failed';
  targetPixels?: 'passed' | 'failed';
  encoder?: string;
  proofLevel?: string;
  proofHash?: string;
}
