import type { AgentInfo, PlanRecord } from '../types.js';

export interface AuthoringProps {
  agent: AgentInfo | undefined;
  agentStatus: string;
  appUrl: string;
  setAppUrl: (v: string) => void;
  feature: string;
  setFeature: (v: string) => void;
  sourceConsent: boolean;
  setSourceConsent: (v: boolean) => void;
  snapshotConsent: boolean;
  setSnapshotConsent: (v: boolean) => void;
  onInspect: () => void;
  onPropose: () => void;
  onCancel: () => void;
  proposing: boolean;
  log: string;

  plans: PlanRecord[];
  selectedPlan: string;
  onSelectPlan: (path: string) => void;
  planText: string;
  setPlanText: (v: string) => void;
  savePath: string;
  setSavePath: (v: string) => void;
  onValidate: () => void;
  validation: string;
  validationError: boolean;

  canApprove: boolean;
  onApprove: () => void;
  canRun: boolean;
  onRun: () => void;
  canStop: boolean;
  onStop: () => void;
  showSavePath: boolean;
}

export function ChatPanel(props: AuthoringProps): JSX.Element {
  const agentAvailable = props.agent?.available ?? false;
  return (
    <>
      <section aria-labelledby="authoring-title">
        <span className="section-label" id="authoring-title">
          AI chat
        </span>
        <p className="hint" role="status" style={{ marginTop: 'var(--s1)' }}>
          {props.agentStatus}
        </p>
        <label className="field">
          Running application URL
          <input
            type="url"
            value={props.appUrl}
            onChange={(e) => props.setAppUrl(e.target.value)}
          />
        </label>
        <label className="field" style={{ marginTop: 'var(--s3)' }}>
          Describe the feature
          <textarea
            rows={4}
            value={props.feature}
            placeholder="Show how to create a project"
            onChange={(e) => props.setFeature(e.target.value)}
          />
        </label>
        <fieldset style={{ marginTop: 'var(--s3)' }}>
          <legend>Agent permission review</legend>
          <label>
            <input
              type="checkbox"
              checked={props.sourceConsent}
              onChange={(e) => props.setSourceConsent(e.target.checked)}
            />
            Allow read-only project source access
          </label>
          <label>
            <input
              type="checkbox"
              checked={props.snapshotConsent}
              onChange={(e) => props.setSnapshotConsent(e.target.checked)}
            />
            Include bounded accessibility snapshot
          </label>
          <p>Screenshots, environment variables, cookies, storage, and secrets are excluded.</p>
        </fieldset>
        <div className="btn-row" style={{ marginTop: 'var(--s3)' }}>
          <button type="button" className="btn" onClick={props.onInspect}>
            Inspect app
          </button>
          <button
            type="button"
            className="btn primary"
            onClick={props.onPropose}
            disabled={props.proposing || !agentAvailable}
          >
            Propose plan
          </button>
          <button
            type="button"
            className="btn"
            onClick={props.onCancel}
            disabled={!props.proposing}
          >
            Cancel
          </button>
        </div>
        <div className="chat-log" aria-live="polite" style={{ marginTop: 'var(--s3)' }}>
          {props.log}
        </div>
      </section>

      <section aria-labelledby="plan-source-title">
        <span className="section-label" id="plan-source-title">
          Demo plan source
        </span>
        <label className="field" style={{ marginTop: 'var(--s2)' }}>
          Existing plans
          <select value={props.selectedPlan} onChange={(e) => props.onSelectPlan(e.target.value)}>
            <option value="">Choose a plan</option>
            {props.plans.map((p) => (
              <option key={p.path} value={p.path}>
                {p.valid ? '✓' : '✕'} {p.path}
              </option>
            ))}
          </select>
        </label>
        {props.showSavePath ? (
          <label className="field" style={{ marginTop: 'var(--s3)' }}>
            Save path
            <input
              type="text"
              value={props.savePath}
              onChange={(e) => props.setSavePath(e.target.value)}
            />
          </label>
        ) : null}
        <label className="field" style={{ marginTop: 'var(--s3)' }}>
          Plan (JSON)
          <textarea
            rows={12}
            spellCheck={false}
            value={props.planText}
            aria-label="Proposed Demo Plan JSON"
            onChange={(e) => props.setPlanText(e.target.value)}
          />
        </label>
        <p
          className={props.validationError ? 'error-line' : 'hint'}
          role="status"
          style={{ marginTop: 'var(--s2)' }}
        >
          {props.validation}
        </p>
        <div className="btn-row" style={{ marginTop: 'var(--s3)' }}>
          <button type="button" className="btn" onClick={props.onValidate}>
            Validate edited plan
          </button>
        </div>
      </section>

      <section aria-labelledby="approval-title">
        <span className="section-label" id="approval-title">
          Approve and run
        </span>
        <div className="btn-row" style={{ marginTop: 'var(--s2)' }}>
          <button
            type="button"
            className="btn primary"
            onClick={props.onApprove}
            disabled={!props.canApprove}
          >
            Approve plan
          </button>
          <button type="button" className="btn" onClick={props.onRun} disabled={!props.canRun}>
            Start run
          </button>
          <button
            type="button"
            className="btn danger"
            onClick={props.onStop}
            disabled={!props.canStop}
          >
            Stop run
          </button>
        </div>
      </section>
    </>
  );
}
