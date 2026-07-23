import { type ChildProcessWithoutNullStreams, spawn, spawnSync } from 'node:child_process';
import {
  type AgentEvent,
  type AgentProvider,
  type ProposeDemoPlanRequest,
  ProposedDemoSchema,
} from './types.js';

const MAX_OUTPUT_BYTES = 2 * 1024 * 1024;
const MAX_STDERR_BYTES = 32 * 1024;
const DEFAULT_TIMEOUT_MS = 120_000;

function boundedAppend(current: string, chunk: string, maximum: number): string {
  return `${current}${chunk}`.slice(-maximum);
}

function extractJson(value: string): unknown {
  const trimmed = value
    .trim()
    .replace(/^```(?:json)?\s*/u, '')
    .replace(/\s*```$/u, '');
  return JSON.parse(trimmed);
}

function safePrompt(request: ProposeDemoPlanRequest): string {
  const context = {
    request: request.featureRequest.slice(0, 8_000),
    initialUrl: request.initialUrl,
    access: {
      sourceFiles: request.consent.sourceFiles,
      semanticSnapshot: request.consent.semanticSnapshot,
      existingPlansAndTests: request.consent.existingPlansAndTests,
      screenshots: false,
    },
    ...(request.snapshot && request.consent.semanticSnapshot
      ? { semanticSnapshot: request.snapshot }
      : {}),
    ...(request.sourceContext && request.consent.sourceFiles
      ? { approvedSourceContext: request.sourceContext }
      : {}),
    ...(request.previousProposal ? { previousProposal: request.previousProposal } : {}),
    ...(request.revisionRequest
      ? { revisionRequest: request.revisionRequest.slice(0, 4_000) }
      : {}),
  };
  return `You are Soredemo's read-only Demo Plan author. Return only one JSON object.
Use exactly schemaVersion 1 and keys: title, summary, assumptions, estimatedDurationMs when useful, plan, unresolved, warnings.
The embedded plan must use the existing Soredemo plan schema and only goto, wait, moveTo, click, type, scrollTo.
Prefer semantic targets and never guess through ambiguity. Never edit files or run commands. Do not include secrets.
Context:\n${JSON.stringify(context)}`;
}

export class ClaudeCodeProvider implements AgentProvider {
  readonly id = 'claude-code';
  readonly displayName = 'Claude Code';
  private readonly children = new Map<string, ChildProcessWithoutNullStreams>();

  constructor(
    private readonly executable = 'claude',
    private readonly timeoutMs = DEFAULT_TIMEOUT_MS,
  ) {}

  async checkAvailability() {
    const result = spawnSync(this.executable, ['--version'], {
      encoding: 'utf8',
      timeout: 5_000,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (result.status !== 0) {
      return {
        available: false,
        reason: 'Claude Code was not found or did not report a compatible version.',
        capabilities: [],
      };
    }
    return {
      available: true,
      version: result.stdout.trim().slice(0, 120),
      capabilities: [
        'non-interactive',
        'json-output',
        'plan-permission-mode',
        'bounded-turns',
        'session-resume',
      ],
    };
  }

  async *proposePlan(request: ProposeDemoPlanRequest): AsyncIterable<AgentEvent> {
    yield* this.invoke(request);
  }

  async *revisePlan(request: ProposeDemoPlanRequest): AsyncIterable<AgentEvent> {
    yield* this.invoke(request);
  }

  async cancel(conversationId: string): Promise<void> {
    const child = this.children.get(conversationId);
    if (!child) return;
    child.kill('SIGTERM');
    await new Promise((resolve) => setTimeout(resolve, 500));
    if (child.exitCode === null) child.kill('SIGKILL');
  }

  private async *invoke(request: ProposeDemoPlanRequest): AsyncIterable<AgentEvent> {
    if (this.children.has(request.conversationId))
      throw new Error('Agent conversation is already active');
    yield { type: 'agent.started', conversationId: request.conversationId };
    const args = [
      '-p',
      '--output-format',
      'json',
      '--permission-mode',
      'plan',
      '--max-turns',
      '4',
      '--disallowedTools',
      'Bash,Edit,Write,NotebookEdit,Read,Glob,Grep,WebFetch,WebSearch',
    ];
    const child = spawn(this.executable, args, {
      cwd: request.projectRoot,
      env: {
        PATH: process.env.PATH,
        HOME: process.env.HOME,
        USER: process.env.USER,
        SHELL: process.env.SHELL,
        DISABLE_AUTOUPDATER: '1',
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.children.set(request.conversationId, child);
    let stdout = '';
    let stderr = '';
    let overflow = false;
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => {
      if (stdout.length + chunk.length > MAX_OUTPUT_BYTES) overflow = true;
      stdout = boundedAppend(stdout, chunk, MAX_OUTPUT_BYTES);
    });
    child.stderr.on('data', (chunk: string) => {
      stderr = boundedAppend(stderr, chunk, MAX_STDERR_BYTES);
    });
    child.stdin.end(safePrompt(request));
    const timer = setTimeout(() => child.kill('SIGTERM'), this.timeoutMs);
    try {
      const code = await new Promise<number | null>((resolve, reject) => {
        child.once('error', reject);
        child.once('close', resolve);
      });
      if (overflow) throw new Error('Agent response exceeded the 2 MiB limit');
      if (code !== 0) throw new Error(`Claude Code exited ${code}: ${stderr.slice(-1_000)}`);
      const envelope = extractJson(stdout) as { result?: string; session_id?: string };
      if (typeof envelope.result !== 'string')
        throw new Error('Claude Code response had no result');
      const proposal = ProposedDemoSchema.parse(extractJson(envelope.result));
      yield {
        type: 'agent.proposal',
        proposal,
        ...(envelope.session_id ? { sessionId: envelope.session_id } : {}),
      };
    } finally {
      clearTimeout(timer);
      this.children.delete(request.conversationId);
    }
  }
}
