import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { chmod, mkdir, readFile, realpath, rm, stat, writeFile } from 'node:fs/promises';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { dirname, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ClaudeCodeProvider } from '../agent/claude-code-provider.js';
import { inspectSemanticApplication } from '../agent/semantic-snapshot.js';
import { collectApprovedSourceContext } from '../agent/source-context.js';
import type { AgentProvider, ProposedDemo } from '../agent/types.js';
import { packageMetadata } from '../cli/package-metadata.js';
import { loadProjectConfiguration } from '../config/load.js';
import { loadDemoPlan } from '../plan/load.js';
import { prepareProofPath } from '../proof/output-path.js';
import { prepareOutputPath } from '../render/output-path.js';
import { RunCoordinator } from '../run-service/run-coordinator.js';
import type { RunEvent } from '../run-service/types.js';
import { ArtifactRegistry } from './artifact-registry.js';
import { StudioError } from './errors.js';
import { discoverDemoPlans } from './plan-discovery.js';
import { planSha256, saveApprovedPlan, validateProposal } from './plan-review.js';

const MAX_BODY_BYTES = 1024 * 1024;
const MAX_SSE_QUEUE = 128;

export interface StudioServerOptions {
  projectRoot: string;
  host?: string;
  port?: number;
  agent?: 'auto' | 'claude-code' | 'none';
  agentProvider?: AgentProvider;
}

export interface StudioServerHandle {
  url: string;
  host: string;
  port: number;
  projectRoot: string;
  pid: number;
  agent: { id: string; displayName: string; available: boolean; version?: string; reason?: string };
  close(): Promise<void>;
}

function isLoopback(host: string): boolean {
  return host === '127.0.0.1' || host === '::1' || host === 'localhost';
}

function sendJson(response: ServerResponse, status: number, value: unknown): void {
  const bytes = Buffer.from(`${JSON.stringify(value)}\n`);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': bytes.byteLength,
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
  });
  response.end(bytes);
}

async function body(request: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += bytes.byteLength;
    if (size > MAX_BODY_BYTES)
      throw new StudioError('STUDIO_START_FAILED', 'Request body is too large', 413);
    chunks.push(bytes);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8')) as Record<string, unknown>;
  } catch {
    throw new StudioError('STUDIO_START_FAILED', 'Request body must be JSON');
  }
}

function inside(root: string, candidate: string): boolean {
  const local = relative(root, candidate);
  return (
    local === '' || (local !== '..' && !local.startsWith(`..${sep}`) && !local.startsWith(sep))
  );
}

async function projectPath(root: string, input: unknown, mustExist = true): Promise<string> {
  if (typeof input !== 'string' || input.length === 0 || input.includes('\0')) {
    throw new StudioError('STUDIO_PATH_INVALID', 'Project path is invalid');
  }
  if (input.startsWith('/') || /^[A-Za-z]:[\\/]/u.test(input)) {
    throw new StudioError('STUDIO_PATH_INVALID', 'Absolute request paths are not accepted');
  }
  const target = resolve(root, input);
  if (!inside(root, target))
    throw new StudioError('STUDIO_PATH_INVALID', 'Path escaped project root');
  if (mustExist) {
    const resolved = await realpath(target).catch(() => {
      throw new StudioError('STUDIO_PATH_INVALID', 'Requested project path does not exist', 404);
    });
    if (!inside(root, resolved))
      throw new StudioError('STUDIO_PATH_INVALID', 'Symlink escaped project root');
    return resolved;
  }
  const parent = await realpath(dirname(target)).catch(() => dirname(target));
  if (!inside(root, parent))
    throw new StudioError('STUDIO_PATH_INVALID', 'Path parent escaped project root');
  return target;
}

function targetOrigin(host: string, port: number): string {
  const scheme = 'http';
  return `${scheme}://${host.includes(':') ? `[${host}]` : host}:${port}`;
}

function authorized(request: IncomingMessage, token: string): boolean {
  return (request.headers.cookie ?? '')
    .split(';')
    .some((entry) => entry.trim() === `soredemo_session=${token}`);
}

function staticMime(path: string): string {
  if (path.endsWith('.css')) return 'text/css; charset=utf-8';
  if (path.endsWith('.js')) return 'text/javascript; charset=utf-8';
  if (path.endsWith('.svg')) return 'image/svg+xml';
  return 'text/html; charset=utf-8';
}

export async function startStudioServer(options: StudioServerOptions): Promise<StudioServerHandle> {
  const projectRoot = await realpath(resolve(options.projectRoot)).catch(() => {
    throw new StudioError('STUDIO_PROJECT_INVALID', 'Project directory does not exist');
  });
  if (!(await stat(projectRoot)).isDirectory())
    throw new StudioError('STUDIO_PROJECT_INVALID', 'Project path is not a directory');
  const host = options.host ?? '127.0.0.1';
  const preferredPort = options.port ?? 0;
  const token = randomBytes(32).toString('base64url');
  const coordinator = new RunCoordinator();
  const artifacts = new ArtifactRegistry(projectRoot);
  const provider =
    options.agentProvider ?? (options.agent === 'none' ? undefined : new ClaudeCodeProvider());
  const availability = provider
    ? await provider.checkAvailability()
    : { available: false, reason: 'No Agent provider configured.', capabilities: [] };
  const agent = {
    id: provider?.id ?? 'none',
    displayName: provider?.displayName ?? 'Manual authoring',
    available: availability.available,
    ...(availability.version ? { version: availability.version } : {}),
    ...(availability.reason ? { reason: availability.reason } : {}),
  };
  const proposals = new Map<string, { proposal: ProposedDemo; hash: string }>();
  const approvedPlanFiles = new Map<string, string>();
  const staticRoot = await realpath(fileURLToPath(new URL('./public/', import.meta.url))).catch(
    () => realpath(fileURLToPath(new URL('../../studio/public/', import.meta.url))),
  );
  let actualPort = 0;

  const server = createServer(async (request, response) => {
    try {
      const origin = targetOrigin(host, actualPort);
      const url = new URL(request.url ?? '/', origin);
      if (
        request.method === 'GET' &&
        (url.pathname === '/' || url.pathname.startsWith('/assets/'))
      ) {
        const relativeFile =
          url.pathname === '/' ? 'index.html' : url.pathname.slice('/assets/'.length);
        if (!/^[a-zA-Z0-9._-]+$/u.test(relativeFile))
          throw new StudioError('STUDIO_PATH_INVALID', 'Invalid static asset path', 404);
        const file = resolve(staticRoot, relativeFile);
        if (!inside(staticRoot, file))
          throw new StudioError('STUDIO_PATH_INVALID', 'Invalid static asset path', 404);
        const bytes = await readFile(file);
        response.writeHead(200, {
          'content-type': staticMime(file),
          'content-length': bytes.byteLength,
          'cache-control': relativeFile === 'index.html' ? 'no-store' : 'public, max-age=3600',
          'set-cookie': `soredemo_session=${token}; HttpOnly; SameSite=Strict; Path=/`,
          'content-security-policy':
            "default-src 'self'; img-src 'self' data: blob:; media-src 'self'; connect-src 'self'; style-src 'self'; script-src 'self'; object-src 'none'; frame-ancestors 'none'",
          'x-frame-options': 'DENY',
          'x-content-type-options': 'nosniff',
        });
        response.end(bytes);
        return;
      }
      if (!url.pathname.startsWith('/api/'))
        throw new StudioError('STUDIO_ARTIFACT_NOT_FOUND', 'Route not found', 404);
      if (!authorized(request, token))
        throw new StudioError('STUDIO_AUTH_INVALID', 'Studio session is not authorized', 401);
      if (request.method !== 'GET') {
        if (request.headers.origin !== origin)
          throw new StudioError('STUDIO_ORIGIN_REJECTED', 'Cross-origin mutation rejected', 403);
      }

      if (request.method === 'GET' && url.pathname === '/api/meta') {
        sendJson(response, 200, {
          product: 'Soredemo Studio',
          version: packageMetadata().version,
          localOnly: isLoopback(host),
          projectRoot,
          agent,
          proofPixelMode: false,
        });
        return;
      }
      if (request.method === 'GET' && url.pathname === '/api/plans') {
        sendJson(response, 200, { plans: await discoverDemoPlans(projectRoot) });
        return;
      }
      if (request.method === 'POST' && url.pathname === '/api/snapshot') {
        const input = await body(request);
        if (input.consent !== true)
          throw new StudioError(
            'AGENT_PERMISSION_REQUIRED',
            'Semantic snapshot requires explicit consent',
            403,
          );
        if (typeof input.url !== 'string')
          throw new StudioError('STUDIO_START_FAILED', 'Application URL is required');
        sendJson(response, 200, await inspectSemanticApplication({ url: input.url }));
        return;
      }
      if (request.method === 'POST' && url.pathname === '/api/agent/propose') {
        if (!provider || !availability.available)
          throw new StudioError('AGENT_UNAVAILABLE', agent.reason ?? 'Agent unavailable', 409);
        const input = await body(request);
        const consent = input.consent as Record<string, unknown> | undefined;
        if (
          !consent ||
          typeof consent.sourceFiles !== 'boolean' ||
          typeof consent.semanticSnapshot !== 'boolean'
        ) {
          throw new StudioError(
            'AGENT_PERMISSION_REQUIRED',
            'Review and submit Agent permissions first',
            403,
          );
        }
        const conversationId =
          typeof input.conversationId === 'string' ? input.conversationId : randomUUID();
        let proposal: ProposedDemo | undefined;
        for await (const event of provider.proposePlan({
          conversationId,
          featureRequest: String(input.featureRequest ?? '').slice(0, 8_000),
          projectRoot,
          initialUrl: String(input.initialUrl ?? ''),
          consent: {
            sourceFiles: consent.sourceFiles,
            semanticSnapshot: consent.semanticSnapshot,
            existingPlansAndTests: consent.existingPlansAndTests === true,
            screenshots: false,
          },
          ...(input.snapshot ? { snapshot: input.snapshot as never } : {}),
          ...(consent.sourceFiles
            ? {
                sourceContext: await collectApprovedSourceContext({
                  projectRoot,
                  includePlansAndTests: consent.existingPlansAndTests === true,
                }),
              }
            : {}),
        })) {
          if (event.type === 'agent.proposal') proposal = validateProposal(event.proposal);
        }
        if (!proposal)
          throw new StudioError('AGENT_PROPOSAL_INVALID', 'Agent returned no valid proposal', 422);
        const hash = planSha256(proposal.plan);
        proposals.set(conversationId, { proposal, hash });
        sendJson(response, 200, { conversationId, proposal, planHash: hash });
        return;
      }
      if (request.method === 'POST' && url.pathname === '/api/agent/cancel') {
        if (!provider) throw new StudioError('AGENT_UNAVAILABLE', 'No Agent provider is configured', 409);
        const input = await body(request);
        if (typeof input.conversationId !== 'string') {
          throw new StudioError('AGENT_PROPOSAL_INVALID', 'Conversation ID is required');
        }
        await provider.cancel(input.conversationId);
        sendJson(response, 200, { cancelled: true, conversationId: input.conversationId });
        return;
      }
      if (request.method === 'POST' && url.pathname === '/api/plans/approve') {
        const input = await body(request);
        const conversationId = String(input.conversationId ?? '');
        const approved = proposals.get(conversationId);
        if (!approved || input.planHash !== approved.hash)
          throw new StudioError(
            'AGENT_PROPOSAL_INVALID',
            'Approval does not match the exact proposed plan',
            409,
          );
        const saved = await saveApprovedPlan({
          projectRoot,
          relativePath: String(input.path ?? ''),
          proposal: approved.proposal,
          approvedHash: approved.hash,
        });
        approvedPlanFiles.set(saved.path, saved.sha256);
        sendJson(response, 200, {
          approved: true,
          planHash: approved.hash,
          path: relative(projectRoot, saved.path),
        });
        return;
      }
      if (request.method === 'POST' && url.pathname === '/api/plans/existing/approve') {
        const input = await body(request);
        const planFile = await projectPath(projectRoot, input.path);
        await loadDemoPlan(planFile);
        const hash = createHash('sha256')
          .update(await readFile(planFile))
          .digest('hex');
        approvedPlanFiles.set(planFile, hash);
        sendJson(response, 200, {
          approved: true,
          planHash: hash,
          path: relative(projectRoot, planFile),
        });
        return;
      }
      if (request.method === 'GET' && url.pathname === '/api/runs') {
        sendJson(response, 200, { runs: coordinator.list() });
        return;
      }
      if (request.method === 'POST' && url.pathname === '/api/runs') {
        const input = await body(request);
        if (input.approved !== true)
          throw new StudioError(
            'AGENT_PERMISSION_REQUIRED',
            'Explicit plan approval is required',
            403,
          );
        const planFile = await projectPath(projectRoot, input.planPath);
        const requestedOutput = await projectPath(projectRoot, input.outputPath, false);
        const requestedProof = await projectPath(projectRoot, input.proofPath, false);
        const outputPath = await prepareOutputPath(planFile, requestedOutput);
        const proofPath = await prepareProofPath(requestedProof);
        const currentHash = createHash('sha256')
          .update(await readFile(planFile))
          .digest('hex');
        if (approvedPlanFiles.get(planFile) !== currentHash) {
          throw new StudioError(
            'AGENT_PERMISSION_REQUIRED',
            'Approval is missing or the plan changed after approval',
            403,
          );
        }
        const plan = await loadDemoPlan(planFile);
        const configuration = await loadProjectConfiguration(planFile);
        const started = coordinator.start({
          plan,
          planFile,
          configuration,
          outputPath,
          proofPath,
          initiator: 'studio',
          keepArtifacts: false,
        });
        void started.completion
          .then(async (result) => {
            await artifacts.register({
              id: `${started.runId}-video`,
              runId: started.runId,
              kind: 'mp4',
              path: result.outputPath,
              mimeType: 'video/mp4',
            });
            const proof = coordinator.get(started.runId).proof;
            if (proof) {
              await artifacts.register({
                id: `${started.runId}-proof`,
                runId: started.runId,
                kind: 'proof',
                path: resolve(proof.path, 'manifest.json'),
                mimeType: 'application/json; charset=utf-8',
              });
            }
          })
          .catch(() => undefined);
        sendJson(response, 202, { runId: started.runId });
        return;
      }
      const runMatch = url.pathname.match(/^\/api\/runs\/([^/]+)$/u);
      if (request.method === 'GET' && runMatch?.[1]) {
        sendJson(response, 200, coordinator.get(runMatch[1]));
        return;
      }
      const stopMatch = url.pathname.match(/^\/api\/runs\/([^/]+)\/stop$/u);
      if (request.method === 'POST' && stopMatch?.[1]) {
        sendJson(response, 200, await coordinator.stop(stopMatch[1]));
        return;
      }
      const eventMatch = url.pathname.match(/^\/api\/runs\/([^/]+)\/events$/u);
      if (request.method === 'GET' && eventMatch?.[1]) {
        const runId = eventMatch[1];
        const after = Number(
          url.searchParams.get('after') ?? request.headers['last-event-id'] ?? 0,
        );
        if (!Number.isSafeInteger(after) || after < 0)
          throw new StudioError('STUDIO_EVENT_SEQUENCE_INVALID', 'Invalid event sequence');
        response.writeHead(200, {
          'content-type': 'text/event-stream',
          'cache-control': 'no-store',
          connection: 'keep-alive',
          'x-accel-buffering': 'no',
        });
        const queue: RunEvent[] = [];
        let writing = false;
        const flush = (): void => {
          if (writing) return;
          writing = true;
          while (queue.length > 0) {
            const event = queue.shift();
            if (!event) break;
            if (
              !response.write(
                `id: ${event.sequence}\nevent: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`,
              )
            )
              break;
          }
          writing = false;
        };
        const enqueue = (event: RunEvent): void => {
          if (queue.length >= MAX_SSE_QUEUE) {
            const preview = queue.findIndex((candidate) => candidate.type === 'capture.preview');
            if (preview >= 0) queue.splice(preview, 1);
            else {
              response.destroy(new Error('Studio event client is too slow'));
              return;
            }
          }
          queue.push(event);
          flush();
        };
        for (const event of coordinator.eventsAfter(runId, after)) enqueue(event);
        const unsubscribe = coordinator.subscribe(runId, enqueue);
        const heartbeat = setInterval(() => response.write(': keepalive\n\n'), 15_000);
        request.once('close', () => {
          clearInterval(heartbeat);
          unsubscribe();
        });
        return;
      }
      const artifactMatch = url.pathname.match(/^\/api\/artifacts\/([^/]+)$/u);
      if (request.method === 'GET' && artifactMatch?.[1]) {
        const entry = artifacts.get(artifactMatch[1]);
        const info = await stat(entry.path);
        response.writeHead(200, {
          'content-type': entry.mimeType,
          'content-length': info.size,
          'content-disposition': 'inline',
          'x-content-type-options': 'nosniff',
        });
        createReadStream(entry.path).pipe(response);
        return;
      }
      throw new StudioError('STUDIO_ARTIFACT_NOT_FOUND', 'Route not found', 404);
    } catch (error) {
      const studio =
        error instanceof StudioError
          ? error
          : new StudioError(
              'STUDIO_START_FAILED',
              error instanceof Error ? error.message : String(error),
              500,
            );
      sendJson(response, studio.statusCode, {
        success: false,
        code: studio.code,
        message: studio.message,
      });
    }
  });

  await new Promise<void>((accept, reject) => {
    server.once('error', reject);
    server.listen(preferredPort, host, accept);
  }).catch((error) => {
    throw new StudioError(
      'STUDIO_PORT_UNAVAILABLE',
      error instanceof Error ? error.message : String(error),
    );
  });
  const address = server.address();
  if (!address || typeof address === 'string')
    throw new StudioError('STUDIO_START_FAILED', 'Studio did not bind a TCP port');
  actualPort = address.port;
  const url = `http://${host.includes(':') ? `[${host}]` : host}:${actualPort}`;
  const descriptor = resolve(projectRoot, '.soredemo/studio.json');
  await mkdir(dirname(descriptor), { recursive: true, mode: 0o700 });
  try {
    const stale = JSON.parse(await readFile(descriptor, 'utf8')) as { pid?: number };
    if (typeof stale.pid === 'number') {
      try {
        process.kill(stale.pid, 0);
        await new Promise<void>((accept) => server.close(() => accept()));
        throw new StudioError(
          'STUDIO_RUN_CONFLICT',
          `Another Studio process (${stale.pid}) owns this project endpoint`,
          409,
        );
      } catch (error) {
        if (error instanceof StudioError) throw error;
      }
    }
    await rm(descriptor, { force: true });
  } catch (error) {
    if (error instanceof StudioError) throw error;
  }
  await writeFile(
    descriptor,
    `${JSON.stringify({ schemaVersion: 1, host, port: actualPort, pid: process.pid })}\n`,
    { mode: 0o600, flag: 'wx' },
  );
  await chmod(descriptor, 0o600);

  return {
    url,
    host,
    port: actualPort,
    projectRoot,
    pid: process.pid,
    agent,
    async close() {
      for (const run of coordinator.list()) {
        if (!['completed', 'failed', 'stopped'].includes(run.state))
          await coordinator.stop(run.runId);
      }
      server.closeAllConnections();
      await new Promise<void>((accept) => server.close(() => accept()));
      await rm(descriptor, { force: true });
    },
  };
}
