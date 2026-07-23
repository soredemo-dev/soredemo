const $ = (id) => document.getElementById(id);
let snapshot;
let proposal;
let conversationId;
let planHash;
let approvedPath;
let runId;
let source;
let planRecords = [];

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: { 'content-type': 'application/json', ...(options.headers || {}) },
  });
  const value = await response.json();
  if (!response.ok) throw new Error(`${value.code}: ${value.message}`);
  return value;
}

function status(message) {
  $('chat-log').textContent = message;
}

async function loadStudio() {
  const [meta, plans] = await Promise.all([api('/api/meta'), api('/api/plans')]);
  $('version').textContent = meta.version;
  $('footer-version').textContent = meta.version;
  $('agent-status').textContent = meta.agent.available
    ? `${meta.agent.displayName} ${meta.agent.version || ''} available`
    : `${meta.agent.displayName}: ${meta.agent.reason || 'unavailable'} — manual plans remain available`;
  $('plans').replaceChildren(
    new Option('Choose a plan', ''),
    ...plans.plans.map((plan) => new Option(`${plan.valid ? '✓' : '✕'} ${plan.path}`, plan.path)),
  );
  planRecords = plans.plans;
}

$('inspect').addEventListener('click', async () => {
  if (!$('snapshot-consent').checked) return status('Enable accessibility snapshot consent first.');
  status('Collecting a bounded, non-authoritative semantic snapshot…');
  try {
    snapshot = await api('/api/snapshot', {
      method: 'POST',
      body: JSON.stringify({ url: $('app-url').value, consent: true }),
    });
    status(`Snapshot collected: ${snapshot.elements.length} visible semantic elements.`);
  } catch (error) {
    status(error.message);
  }
});

$('propose').addEventListener('click', async () => {
  status('External Agent is proposing a reviewable plan…');
  $('propose').disabled = true;
  conversationId ||= crypto.randomUUID();
  $('cancel-agent').disabled = false;
  try {
    const result = await api('/api/agent/propose', {
      method: 'POST',
      body: JSON.stringify({
        conversationId,
        featureRequest: $('feature').value,
        initialUrl: $('app-url').value,
        consent: {
          sourceFiles: $('source-consent').checked,
          semanticSnapshot: $('snapshot-consent').checked,
          existingPlansAndTests: $('source-consent').checked,
        },
        snapshot,
      }),
    });
    conversationId = result.conversationId;
    proposal = result.proposal;
    planHash = result.planHash;
    $('plan-json').value = JSON.stringify(proposal.plan, null, 2);
    $('validation').textContent =
      `Valid proposal · ${proposal.plan.actions.length} supported actions · approval hash ${planHash.slice(0, 12)}…`;
    $('approve').disabled = proposal.unresolved.length > 0;
    status(proposal.summary);
  } catch (error) {
    status(error.message);
  } finally {
    $('propose').disabled = false;
    $('cancel-agent').disabled = true;
  }
});

$('cancel-agent').addEventListener('click', async () => {
  if (!conversationId) return;
  try {
    await api('/api/agent/cancel', {
      method: 'POST',
      body: JSON.stringify({ conversationId }),
    });
    status('Agent request cancelled.');
  } catch (error) {
    status(error.message);
  }
});

$('plan-json').addEventListener('input', () => {
  $('approve').disabled = true;
  $('run').disabled = true;
  $('validation').textContent = 'Plan changed; prior approval is invalid.';
});

$('plans').addEventListener('change', () => {
  const selected = planRecords.find((plan) => plan.path === $('plans').value);
  if (!selected) return;
  approvedPath = selected.path;
  conversationId = undefined;
  proposal = undefined;
  $('plan-json').value = JSON.stringify(
    {
      path: selected.path,
      url: selected.url,
      actions: selected.actions.map((action) => ({
        ...action,
        ...(action.textLength === undefined
          ? {}
          : { text: `<redacted: ${action.textLength} characters>` }),
      })),
    },
    null,
    2,
  );
  $('validation').textContent = selected.valid
    ? `Valid existing plan · ${selected.actionCount} actions · typed values redacted`
    : selected.error;
  $('approve').disabled = !selected.valid;
});

$('approve').addEventListener('click', async () => {
  try {
    const result = conversationId
      ? await api('/api/plans/approve', {
          method: 'POST',
          body: JSON.stringify({ conversationId, planHash, path: $('plan-path').value }),
        })
      : await api('/api/plans/existing/approve', {
          method: 'POST',
          body: JSON.stringify({ path: approvedPath }),
        });
    approvedPath = result.path;
    $('validation').textContent = `Approved and saved ${result.path}`;
    $('run').disabled = false;
  } catch (error) {
    $('validation').textContent = error.message;
  }
});

$('run').addEventListener('click', async () => {
  const stem = approvedPath.replace(/^demos\//, '').replace(/\.ya?ml$/, '');
  const result = await api('/api/runs', {
    method: 'POST',
    body: JSON.stringify({
      approved: true,
      planPath: approvedPath,
      outputPath: `output/${stem}.mp4`,
      proofPath: `output/${stem}.proof`,
    }),
  });
  runId = result.runId;
  $('run').disabled = true;
  $('stop').disabled = false;
  observe();
});

function observe() {
  source?.close();
  source = new EventSource(`/api/runs/${runId}/events`);
  source.onmessage = handleEvent;
  for (const type of [
    'run.started',
    'action.started',
    'action.completed',
    'capture.preview',
    'capture.metrics',
    'cursor.landing',
    'compose.started',
    'encode.started',
    'proof.updated',
    'proof.completed',
    'run.completed',
    'run.failed',
    'run.stopped',
  ]) {
    source.addEventListener(type, handleEvent);
  }
}

function handleEvent(message) {
  const event = JSON.parse(message.data);
  $('run-live').textContent = `${event.type} ${event.sequence}`;
  if (event.type === 'capture.preview') {
    $('preview').src = `data:image/jpeg;base64,${event.payload.jpegBase64}`;
    $('preview-status').textContent =
      `Capture frame ${event.payload.captureFrameIndex}, sampled preview`;
  } else if (event.type === 'action.started') {
    $('current-action').textContent =
      `Action ${event.payload.actionIndex + 1}: ${event.payload.actionKind}`;
    $('target').textContent = event.payload.targetDescription || 'not applicable';
  } else if (event.type === 'capture.metrics') {
    $('scale').textContent = event.payload.passed ? 'passed — genuine painted DPR 2' : 'failed';
  } else if (event.type === 'cursor.landing') {
    $('cursor').textContent = event.payload.failures === 0 ? 'passed' : 'failed';
    $('pixels').textContent = event.payload.failures === 0 ? 'passed' : 'failed';
  } else if (event.type === 'encode.started') {
    $('encoder').textContent = 'encoding with bounded backpressure';
  } else if (event.type === 'proof.completed') {
    $('proof').textContent =
      `${event.payload.level} · ${event.payload.manifestSha256.slice(0, 12)}…`;
    $('proof-link').href = `/api/artifacts/${runId}-proof`;
    $('proof-link').hidden = false;
  } else if (event.type === 'run.completed') {
    $('run-state').textContent = 'completed';
    $('stop').disabled = true;
    $('video').src = `/api/artifacts/${runId}-video`;
    $('video').hidden = false;
    source.close();
  } else if (event.type === 'run.failed' || event.type === 'run.stopped') {
    $('run-state').textContent = event.type.replace('run.', '');
    $('stop').disabled = true;
    source.close();
  } else {
    $('run-state').textContent = event.type.replace('.', ' · ');
  }
}

$('stop').addEventListener('click', async () => {
  if (!runId) return;
  await api(`/api/runs/${runId}/stop`, { method: 'POST', body: '{}' });
});

window.addEventListener('beforeunload', () => source?.close());
loadStudio().catch((error) => status(error.message));
