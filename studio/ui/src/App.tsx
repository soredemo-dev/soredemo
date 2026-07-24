import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ApiError, api, artifactUrl } from './api.js';
import { Glyph } from './brand.js';
import { ChatPanel } from './components/ChatPanel.js';
import { type ApprovalState, PlanRail } from './components/PlanRail.js';
import { PreviewStage } from './components/PreviewStage.js';
import { StatusBar } from './components/StatusBar.js';
import type {
  DiscoveredAction,
  Evidence,
  Meta,
  PlanAction,
  PlanRecord,
  Proposal,
  RunEvent,
  RunPhase,
  StepView,
} from './types.js';

const RUN_EVENT_TYPES = [
  'run.created',
  'run.validating',
  'run.ready',
  'run.started',
  'action.resolving',
  'action.resolved',
  'action.started',
  'action.completed',
  'action.failed',
  'capture.preview',
  'capture.metrics',
  'cursor.landing',
  'target.pixelProof',
  'compose.started',
  'compose.progress',
  'compose.completed',
  'encode.started',
  'encode.progress',
  'encode.completed',
  'proof.updated',
  'proof.completed',
  'run.stopping',
  'run.stopped',
  'run.completed',
  'run.failed',
];

function describeTarget(action: PlanAction): string {
  if (action.action === 'goto') return typeof action.url === 'string' ? action.url : '';
  const t = action.target as Record<string, unknown> | undefined;
  if (!t) return '';
  if (typeof t.testId === 'string') return `testId="${t.testId}"`;
  if (typeof t.role === 'string')
    return `role=${t.role}${typeof t.name === 'string' ? ` "${t.name}"` : ''}`;
  if (typeof t.label === 'string') return `label="${t.label}"`;
  if (typeof t.text === 'string') return `text="${t.text}"`;
  if (typeof t.css === 'string') return t.css;
  return '';
}

function stepsFromActions(actions: PlanAction[]): StepView[] {
  return actions.map((action, index) => ({
    index,
    action: action.action,
    target: describeTarget(action),
    state: 'pending',
  }));
}

// Existing-plan discovery returns a different, already-summarized action shape.
function stepsFromDiscovered(actions: DiscoveredAction[]): StepView[] {
  return actions.map((action, index) => ({
    index,
    action: action.kind,
    target: action.target ?? '',
    state: 'pending',
  }));
}

export function App(): JSX.Element {
  const [meta, setMeta] = useState<Meta | undefined>();
  const [plans, setPlans] = useState<PlanRecord[]>([]);
  const [agentStatus, setAgentStatus] = useState('Checking Agent provider…');

  const [appUrl, setAppUrl] = useState('http://127.0.0.1:3000');
  const [feature, setFeature] = useState('');
  const [sourceConsent, setSourceConsent] = useState(false);
  const [snapshotConsent, setSnapshotConsent] = useState(false);
  const [log, setLog] = useState('Describe a feature, or select an existing plan.');
  const [proposing, setProposing] = useState(false);
  const snapshotRef = useRef<unknown>(undefined);

  const [conversationId, setConversationId] = useState<string | undefined>();
  const [planHash, setPlanHash] = useState<string | undefined>();
  const [planText, setPlanText] = useState('');
  const [savePath, setSavePath] = useState('demos/ai-proposal.yaml');
  const [selectedPlan, setSelectedPlan] = useState('');
  const [approvedPath, setApprovedPath] = useState<string | undefined>();
  const [approval, setApproval] = useState<ApprovalState>('none');
  const [validation, setValidation] = useState('Select or propose a plan.');
  const [validationError, setValidationError] = useState(false);

  const [steps, setSteps] = useState<StepView[]>([]);
  const [phase, setPhase] = useState<RunPhase>('idle');
  const [evidence, setEvidence] = useState<Evidence>({});
  const [previewSrc, setPreviewSrc] = useState<string | undefined>();
  const [videoSrc, setVideoSrc] = useState<string | undefined>();
  const [proofHref, setProofHref] = useState<string | undefined>();
  const [lastEvent, setLastEvent] = useState('');
  const runIdRef = useRef<string | undefined>(undefined);
  const sourceRef = useRef<EventSource | undefined>(undefined);
  const [running, setRunning] = useState(false);

  const upsertStep = useCallback((index: number, patch: Partial<StepView>) => {
    setSteps((prev) => {
      const next = prev.slice();
      const existing = next[index] ?? {
        index,
        action: patch.action ?? 'action',
        target: '',
        state: 'pending' as const,
      };
      next[index] = { ...existing, ...patch, index };
      return next;
    });
  }, []);

  const handleEvent = useCallback(
    (event: RunEvent) => {
      const p = event.payload ?? {};
      setLastEvent(`${event.type} · #${event.sequence}`);
      switch (event.type) {
        case 'run.started':
          setPhase('capturing');
          break;
        case 'action.resolving':
          upsertStep(Number(p.actionIndex ?? 0), {
            state: 'resolving',
            action: String(p.actionKind ?? 'action'),
            ...(typeof p.targetDescription === 'string' ? { target: p.targetDescription } : {}),
          });
          break;
        case 'action.started':
          upsertStep(Number(p.actionIndex ?? 0), {
            state: 'active',
            action: String(p.actionKind ?? 'action'),
            ...(typeof p.targetDescription === 'string' ? { target: p.targetDescription } : {}),
          });
          break;
        case 'action.completed':
          upsertStep(Number(p.actionIndex ?? 0), { state: 'completed' });
          break;
        case 'action.failed':
          upsertStep(Number(p.actionIndex ?? 0), {
            state: 'failed',
            ...(typeof p.code === 'string' ? { errorCode: p.code } : {}),
            ...(typeof p.message === 'string' ? { errorMessage: p.message } : {}),
          });
          break;
        case 'capture.preview':
          if (typeof p.jpegBase64 === 'string') {
            setPreviewSrc(`data:image/jpeg;base64,${p.jpegBase64}`);
          }
          break;
        case 'capture.metrics':
          setEvidence((e) => ({ ...e, captureScale: p.passed ? 'passed' : 'failed' }));
          break;
        case 'cursor.landing': {
          const ok = Number(p.failures ?? 0) === 0;
          setEvidence((e) => ({ ...e, cursorLanding: ok ? 'passed' : 'failed' }));
          setSteps((prev) =>
            prev.map((s) =>
              s.state === 'completed' &&
              (s.action === 'click' || s.action === 'moveTo' || s.action === 'type')
                ? { ...s, cursorVerified: ok }
                : s,
            ),
          );
          break;
        }
        case 'target.pixelProof': {
          const ok = Number(p.failures ?? 0) === 0;
          setEvidence((e) => ({ ...e, targetPixels: ok ? 'passed' : 'failed' }));
          setSteps((prev) =>
            prev.map((s) =>
              s.state === 'completed' && (s.action === 'click' || s.action === 'moveTo')
                ? { ...s, pixelsVerified: ok }
                : s,
            ),
          );
          break;
        }
        case 'compose.started':
        case 'compose.progress':
          setPhase('composing');
          break;
        case 'encode.started':
          setPhase('encoding');
          setEvidence((e) => ({ ...e, encoder: 'bounded backpressure (≤1 pending frame)' }));
          break;
        case 'proof.completed':
          setEvidence((e) => ({
            ...e,
            ...(typeof p.level === 'string' ? { proofLevel: p.level } : {}),
            ...(typeof p.manifestSha256 === 'string' ? { proofHash: p.manifestSha256 } : {}),
          }));
          if (runIdRef.current) setProofHref(artifactUrl(`${runIdRef.current}-proof`));
          break;
        case 'run.completed':
          setPhase('completed');
          setRunning(false);
          if (runIdRef.current) setVideoSrc(artifactUrl(`${runIdRef.current}-video`));
          sourceRef.current?.close();
          break;
        case 'run.failed':
          setPhase('failed');
          setRunning(false);
          sourceRef.current?.close();
          break;
        case 'run.stopped':
          setPhase('stopped');
          setRunning(false);
          sourceRef.current?.close();
          break;
        default:
          break;
      }
    },
    [upsertStep],
  );

  const observe = useCallback(
    (runId: string) => {
      sourceRef.current?.close();
      const source = new EventSource(`/api/runs/${runId}/events`);
      const dispatch = (message: MessageEvent) => {
        try {
          handleEvent(JSON.parse(message.data) as RunEvent);
        } catch {
          /* ignore malformed frame */
        }
      };
      source.onmessage = dispatch;
      for (const type of RUN_EVENT_TYPES) source.addEventListener(type, dispatch as EventListener);
      sourceRef.current = source;
    },
    [handleEvent],
  );

  const loadStudio = useCallback(async () => {
    const [m, planList] = await Promise.all([
      api<Meta>('/api/meta'),
      api<{ plans: PlanRecord[] }>('/api/plans'),
    ]);
    setMeta(m);
    setAgentStatus(
      m.agent.available
        ? `${m.agent.displayName} ${m.agent.version ?? ''} available`.trim()
        : `${m.agent.displayName}: ${m.agent.reason ?? 'unavailable'} — manual plans remain available`,
    );
    setPlans(planList.plans);
  }, []);

  const resumeActiveRun = useCallback(async () => {
    try {
      const list = await api<{ runs: Array<{ runId: string; state: RunPhase }> }>('/api/runs');
      const active = list.runs.find((r) => !['completed', 'failed', 'stopped'].includes(r.state));
      if (active) {
        runIdRef.current = active.runId;
        setRunning(true);
        setApproval('approved');
        setPhase(active.state);
        observe(active.runId);
      }
    } catch {
      /* no active run to resume */
    }
  }, [observe]);

  useEffect(() => {
    loadStudio().catch((e: unknown) => setLog(e instanceof Error ? e.message : String(e)));
    resumeActiveRun().catch(() => undefined);
    return () => sourceRef.current?.close();
  }, [loadStudio, resumeActiveRun]);

  // ---- authoring handlers ----
  const onInspect = useCallback(async () => {
    if (!snapshotConsent) {
      setLog('Enable accessibility snapshot consent first.');
      return;
    }
    setLog('Collecting a bounded, non-authoritative semantic snapshot…');
    try {
      const snap = await api<{ elements: unknown[] }>('/api/snapshot', {
        method: 'POST',
        body: JSON.stringify({ url: appUrl, consent: true }),
      });
      snapshotRef.current = snap;
      setLog(`Snapshot collected: ${snap.elements.length} visible semantic elements.`);
    } catch (e) {
      setLog(e instanceof Error ? e.message : String(e));
    }
  }, [appUrl, snapshotConsent]);

  const applyProposal = useCallback(
    (proposal: Proposal, hash: string, convId: string, kind: 'proposal' | 'manual') => {
      setConversationId(convId);
      setPlanHash(hash);
      setPlanText(JSON.stringify(proposal.plan, null, 2));
      setSteps(stepsFromActions(proposal.plan.actions));
      setApproval('pending');
      setValidationError(false);
      setValidation(
        `Valid ${kind === 'manual' ? 'manual plan' : 'proposal'} · ${proposal.plan.actions.length} supported actions · approval hash ${hash.slice(0, 12)}…`,
      );
    },
    [],
  );

  const onPropose = useCallback(async () => {
    setProposing(true);
    setLog('External Agent is proposing a reviewable plan…');
    const convId = conversationId ?? crypto.randomUUID();
    try {
      const result = await api<{ conversationId: string; proposal: Proposal; planHash: string }>(
        '/api/agent/propose',
        {
          method: 'POST',
          body: JSON.stringify({
            conversationId: convId,
            featureRequest: feature,
            initialUrl: appUrl,
            consent: {
              sourceFiles: sourceConsent,
              semanticSnapshot: snapshotConsent,
              existingPlansAndTests: sourceConsent,
            },
            snapshot: snapshotRef.current,
          }),
        },
      );
      applyProposal(result.proposal, result.planHash, result.conversationId, 'proposal');
      setLog(result.proposal.summary);
    } catch (e) {
      setLog(e instanceof Error ? e.message : String(e));
    } finally {
      setProposing(false);
    }
  }, [appUrl, applyProposal, conversationId, feature, snapshotConsent, sourceConsent]);

  const onCancel = useCallback(async () => {
    if (!conversationId) return;
    try {
      await api('/api/agent/cancel', {
        method: 'POST',
        body: JSON.stringify({ conversationId }),
      });
      setLog('Agent request cancelled.');
    } catch (e) {
      setLog(e instanceof Error ? e.message : String(e));
    } finally {
      setProposing(false);
    }
  }, [conversationId]);

  // user-typed edits invalidate any prior approval
  const onPlanEdit = useCallback((value: string) => {
    setPlanText(value);
    setApproval((prev) => (prev === 'none' ? 'none' : 'invalidated'));
    setValidation('Plan changed; prior approval is invalid. Validate and approve again.');
    setValidationError(false);
  }, []);

  const onValidate = useCallback(async () => {
    try {
      const result = await api<{ conversationId: string; proposal: Proposal; planHash: string }>(
        '/api/plans/manual/validate',
        { method: 'POST', body: JSON.stringify({ plan: JSON.parse(planText) }) },
      );
      applyProposal(result.proposal, result.planHash, result.conversationId, 'manual');
    } catch (e) {
      setValidationError(true);
      setValidation(e instanceof Error ? e.message : String(e));
    }
  }, [applyProposal, planText]);

  const onSelectPlan = useCallback(
    (path: string) => {
      setSelectedPlan(path);
      const record = plans.find((r) => r.path === path);
      if (!record) return;
      setConversationId(undefined);
      setPlanHash(undefined);
      setApprovedPath(record.path);
      const actions = record.actions ?? [];
      setSteps(stepsFromDiscovered(actions));
      setPlanText(
        JSON.stringify(
          {
            path: record.path,
            url: record.url,
            actions: actions.map((a: DiscoveredAction) =>
              a.textLength === undefined
                ? a
                : { ...a, text: `<redacted: ${a.textLength} characters>` },
            ),
          },
          null,
          2,
        ),
      );
      setApproval('pending');
      setValidationError(!record.valid);
      setValidation(
        record.valid
          ? `Valid existing plan · ${record.actionCount ?? actions.length} actions · typed values redacted`
          : (record.error ?? 'Invalid plan'),
      );
    },
    [plans],
  );

  const onApprove = useCallback(async () => {
    try {
      const result = conversationId
        ? await api<{ path: string; planHash: string }>('/api/plans/approve', {
            method: 'POST',
            body: JSON.stringify({ conversationId, planHash, path: savePath }),
          })
        : await api<{ path: string; planHash: string }>('/api/plans/existing/approve', {
            method: 'POST',
            body: JSON.stringify({ path: approvedPath }),
          });
      setApprovedPath(result.path);
      setPlanHash(result.planHash);
      setApproval('approved');
      setValidationError(false);
      setValidation(`Approved and saved ${result.path}`);
    } catch (e) {
      setValidationError(true);
      setValidation(e instanceof Error ? e.message : String(e));
    }
  }, [approvedPath, conversationId, planHash, savePath]);

  const onRun = useCallback(async () => {
    if (!approvedPath) return;
    const stem = approvedPath.replace(/^demos\//, '').replace(/\.ya?ml$/, '');
    setEvidence({});
    setPreviewSrc(undefined);
    setVideoSrc(undefined);
    setProofHref(undefined);
    setSteps((prev) => prev.map((s) => ({ ...s, state: 'pending' })));
    setPhase('running');
    try {
      const result = await api<{ runId: string }>('/api/runs', {
        method: 'POST',
        body: JSON.stringify({
          approved: true,
          planPath: approvedPath,
          outputPath: `output/${stem}.mp4`,
          proofPath: `output/${stem}.proof`,
        }),
      });
      runIdRef.current = result.runId;
      setRunning(true);
      observe(result.runId);
    } catch (e) {
      setPhase('failed');
      setValidationError(true);
      setValidation(e instanceof Error ? e.message : String(e));
    }
  }, [approvedPath, observe]);

  const onStop = useCallback(async () => {
    const runId = runIdRef.current;
    if (!runId) return;
    try {
      await api(`/api/runs/${runId}/stop`, { method: 'POST', body: '{}' });
    } catch (e) {
      if (e instanceof ApiError) setLastEvent(`${e.code}: ${e.message}`);
    }
  }, []);

  // Only a freshly validated/selected plan ('pending') can be approved. Editing
  // sets 'invalidated', which forces a re-validate (back to 'pending') first.
  const canApprove =
    approval === 'pending' && !!(conversationId ? planHash : approvedPath) && !validationError;
  const canRun = approval === 'approved' && !running;
  const canStop = running;

  const captionText = videoSrc
    ? 'Final rendered output — produced by the verified compositor and encoder.'
    : previewSrc
      ? 'Live capture preview — sampled, non-authoritative; final output renders separately.'
      : 'Live capture preview appears here during a run; the final MP4 replaces it when complete.';

  const glyphTitle = useMemo(() => <Glyph />, []);

  return (
    <div className="app">
      <div className="titlebar">
        <span className="brand">
          {glyphTitle}
          Soredemo Studio
        </span>
        <span className="spacer" />
        {meta?.localOnly ? (
          <span className="chip">
            <span className="dot" />
            Local only
          </span>
        ) : (
          <span className="chip" style={{ color: 'var(--attention)' }}>
            Bound beyond loopback
          </span>
        )}
      </div>

      <div className="workspace">
        <aside className="rail left">
          <div className="rail-head">
            <h2>Authoring</h2>
          </div>
          <div className="rail-body">
            <ChatPanel
              agent={meta?.agent}
              agentStatus={agentStatus}
              appUrl={appUrl}
              setAppUrl={setAppUrl}
              feature={feature}
              setFeature={setFeature}
              sourceConsent={sourceConsent}
              setSourceConsent={setSourceConsent}
              snapshotConsent={snapshotConsent}
              setSnapshotConsent={setSnapshotConsent}
              onInspect={onInspect}
              onPropose={onPropose}
              onCancel={onCancel}
              proposing={proposing}
              log={log}
              plans={plans}
              selectedPlan={selectedPlan}
              onSelectPlan={onSelectPlan}
              planText={planText}
              setPlanText={onPlanEdit}
              savePath={savePath}
              setSavePath={setSavePath}
              onValidate={onValidate}
              validation={validation}
              validationError={validationError}
              canApprove={canApprove}
              onApprove={onApprove}
              canRun={canRun}
              onRun={onRun}
              canStop={canStop}
              onStop={onStop}
              showSavePath={!!conversationId}
            />
          </div>
        </aside>

        <PreviewStage
          {...(previewSrc ? { previewSrc } : {})}
          {...(videoSrc ? { videoSrc } : {})}
          captionText={captionText}
          live={running && !videoSrc}
        />

        <aside className="rail right">
          <div className="rail-head">
            <h2>Demo plan</h2>
          </div>
          <div className="rail-body">
            <PlanRail
              steps={steps}
              {...(planHash ? { planHash } : {})}
              approval={approval}
              evidence={evidence}
              {...(proofHref ? { proofHref } : {})}
              videoReady={!!videoSrc}
            />
          </div>
        </aside>
      </div>

      <StatusBar
        phase={phase}
        lastEvent={lastEvent}
        projectRoot={meta?.projectRoot ?? ''}
        version={meta?.version ?? ''}
      />
    </div>
  );
}
