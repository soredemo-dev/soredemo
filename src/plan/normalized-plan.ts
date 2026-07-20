export type Pace = 'fast' | 'balanced' | 'calm';
export type Emphasis = 'primary' | 'secondary' | 'none';

export type Target =
  | { role: string; name: string | null }
  | { label: string }
  | { testId: string }
  | { text: string; exact: boolean }
  | { css: string };

export interface IntentPlan {
  goal: string;
  audience: string | null;
  success: string | null;
  targetDurationMs: number | null;
}

export interface ViewportPlan {
  width: number;
  height: number;
}

export interface StylePlan {
  preset: 'studio';
  pace: Pace;
  seed: number;
}

export type NormalizedAction =
  | { action: 'goto'; url: string }
  | { action: 'wait'; durationMs: number }
  | {
      action: 'wait';
      until: { visible: Target };
      timeoutMs: number;
      settleMs: number;
    }
  | { action: 'moveTo'; target: Target }
  | {
      action: 'click';
      target: Target;
      emphasis: Emphasis;
      focusAfter: { target: Target } | null;
    }
  | { action: 'type'; target: Target; text: string }
  | { action: 'scrollTo'; target: Target; durationMs: number }
  | { action: 'scrollTo'; x: number; y: number; durationMs: number };

export interface ActionPlan {
  version: 1;
  name: string;
  initialUrl: string;
  intent: IntentPlan;
  viewport: ViewportPlan;
  style: StylePlan;
  actions: NormalizedAction[];
}
