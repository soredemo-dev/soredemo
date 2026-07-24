import { useEffect, useRef } from 'react';
import type { Evidence, StepView } from '../types.js';
import { ProofBadge } from './ProofBadge.js';

const VERB: Record<string, string> = {
  goto: 'Go to',
  wait: 'Wait',
  moveTo: 'Move to',
  click: 'Click',
  type: 'Type into',
  scrollTo: 'Scroll to',
};

const STATE_LABEL: Record<string, string> = {
  pending: 'pending',
  resolving: 'resolving',
  active: 'active',
  completed: 'completed',
  failed: 'failed',
};

function ActionStep({ step }: { step: StepView }): JSX.Element {
  const ref = useRef<HTMLLIElement>(null);
  useEffect(() => {
    if (step.state === 'active' || step.state === 'resolving') {
      ref.current?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
  }, [step.state]);
  return (
    <li ref={ref} className={`step ${step.state}`}>
      <div className="step-marker">
        <span className="step-index">{step.index + 1}</span>
      </div>
      <div className="step-body">
        <div className="step-kind">
          <span className="verb">{VERB[step.action] ?? step.action}</span>
          <span className="state">{STATE_LABEL[step.state]}</span>
        </div>
        {step.target ? <span className="step-target">{step.target}</span> : null}
        {(step.cursorVerified || step.pixelsVerified) && step.state === 'completed' ? (
          <div className="step-evidence">
            {step.cursorVerified ? <ProofBadge tone="verified" label="cursor ✓" /> : null}
            {step.pixelsVerified ? <ProofBadge tone="verified" label="target px ✓" /> : null}
          </div>
        ) : null}
        {step.state === 'failed' && step.errorCode ? (
          <div className="step-error">
            <span className="code">{step.errorCode}</span>
            {step.errorMessage ? ` — ${step.errorMessage}` : null}
          </div>
        ) : null}
      </div>
    </li>
  );
}

export type ApprovalState = 'none' | 'pending' | 'approved' | 'invalidated';

export function PlanRail({
  steps,
  planHash,
  approval,
  evidence,
  proofHref,
  videoReady,
  onOpenProof,
}: {
  steps: StepView[];
  planHash?: string;
  approval: ApprovalState;
  evidence: Evidence;
  proofHref?: string;
  videoReady: boolean;
  onOpenProof?: () => void;
}): JSX.Element {
  const approvalClass =
    approval === 'approved' ? 'approved' : approval === 'invalidated' ? 'invalidated' : 'pending';
  const approvalText =
    approval === 'approved'
      ? 'approved'
      : approval === 'invalidated'
        ? 'approval invalidated'
        : approval === 'pending'
          ? 'awaiting approval'
          : 'no plan';
  return (
    <>
      <div className="plan-meta">
        <span className="section-label">Approved plan</span>
        <div className="hash-row">
          <span className="mono">
            {planHash ? `sha256 ${planHash.slice(0, 20)}…` : 'no plan hash'}
          </span>
          <span className={`approval ${approvalClass}`} style={{ marginLeft: 'auto' }}>
            {approvalText}
          </span>
        </div>
      </div>

      {steps.length === 0 ? (
        <p className="hint">
          Propose, paste, or select a plan to see its verified execution checklist.
        </p>
      ) : (
        <ol className="steps" aria-label="Demo plan steps">
          {steps.map((step) => (
            <ActionStep key={step.index} step={step} />
          ))}
        </ol>
      )}

      <div className="evidence">
        <span className="section-label">Run evidence</span>
        <div className="evidence-row">
          <span className="k">Capture scale</span>
          <span className="v">
            {evidence.captureScale === 'passed' ? (
              <ProofBadge tone="verified" label="genuine DPR 2 ✓" />
            ) : evidence.captureScale === 'failed' ? (
              <ProofBadge tone="danger" label="failed" />
            ) : (
              'pending'
            )}
          </span>
        </div>
        <div className="evidence-row">
          <span className="k">Cursor landing</span>
          <span className="v">
            {evidence.cursorLanding === 'passed' ? (
              <ProofBadge tone="verified" label="passed" />
            ) : evidence.cursorLanding === 'failed' ? (
              <ProofBadge tone="danger" label="failed" />
            ) : (
              'pending'
            )}
          </span>
        </div>
        <div className="evidence-row">
          <span className="k">Target pixels</span>
          <span className="v">
            {evidence.targetPixels === 'passed' ? (
              <ProofBadge tone="verified" label="passed" />
            ) : evidence.targetPixels === 'failed' ? (
              <ProofBadge tone="danger" label="failed" />
            ) : (
              'pending'
            )}
          </span>
        </div>
        <div className="evidence-row">
          <span className="k">Encoder</span>
          <span className="v">{evidence.encoder ?? 'pending'}</span>
        </div>
        <div className="evidence-row">
          <span className="k">Proof</span>
          <span className="v">
            {evidence.proofLevel ? (
              <ProofBadge
                tone="verified"
                label={evidence.proofLevel}
                {...(evidence.proofHash ? { value: `${evidence.proofHash.slice(0, 12)}…` } : {})}
              />
            ) : (
              'pending'
            )}
          </span>
        </div>
      </div>

      {(proofHref || videoReady) && (
        <div className="artifact-links">
          <span className="section-label">Artifacts</span>
          {videoReady ? <a href="#video">Jump to rendered video</a> : null}
          {proofHref ? (
            <a href={proofHref} onClick={onOpenProof} target="_blank" rel="noreferrer">
              Open proof manifest (may describe sensitive pixels)
            </a>
          ) : null}
        </div>
      )}
    </>
  );
}
