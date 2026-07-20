import type { ScriptInput, TargetInput } from './input-schema.js';
import type { ActionPlan, NormalizedAction, Target } from './normalized-plan.js';

function normalizeTarget(target: TargetInput): Target {
  if ('role' in target) {
    return {
      role: target.role,
      name: target.name ?? null,
    };
  }
  if ('label' in target) return { label: target.label };
  if ('testId' in target) return { testId: target.testId };
  if ('text' in target) {
    return {
      text: target.text,
      exact: target.exact ?? false,
    };
  }
  return { css: target.css };
}

function normalizeAction(action: ScriptInput['actions'][number]): NormalizedAction {
  switch (action.action) {
    case 'goto':
      return action;
    case 'wait':
      if ('durationMs' in action) return action;
      return {
        action: 'wait',
        until: { visible: normalizeTarget(action.until.visible) },
        timeoutMs: action.timeoutMs ?? 10_000,
        settleMs: action.settleMs ?? 500,
      };
    case 'moveTo':
      return { action: 'moveTo', target: normalizeTarget(action.target) };
    case 'click':
      return {
        action: 'click',
        target: normalizeTarget(action.target),
        emphasis: action.emphasis ?? 'none',
        focusAfter: action.focusAfter
          ? { target: normalizeTarget(action.focusAfter.target) }
          : null,
      };
    case 'type':
      return { action: 'type', target: normalizeTarget(action.target), text: action.text };
    case 'scrollTo':
      if ('target' in action) {
        return {
          action: 'scrollTo',
          target: normalizeTarget(action.target),
          durationMs: action.durationMs,
        };
      }
      return {
        action: 'scrollTo',
        x: action.x ?? 0,
        y: action.y,
        durationMs: action.durationMs,
      };
  }
}

export function normalizeScript(input: ScriptInput): ActionPlan {
  return {
    version: 1,
    name: input.name,
    initialUrl: input.url,
    intent: {
      goal: input.intent.goal,
      audience: input.intent.audience ?? null,
      success: input.intent.success ?? null,
      targetDurationMs: input.intent.targetDurationMs ?? null,
    },
    viewport: {
      width: input.viewport?.width ?? 1440,
      height: input.viewport?.height ?? 900,
    },
    style: {
      preset: input.style?.preset ?? 'studio',
      pace: input.style?.pace ?? 'balanced',
      seed: input.style?.seed ?? 0,
    },
    actions: input.actions.map(normalizeAction),
  };
}
