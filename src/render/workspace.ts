import { randomBytes } from 'node:crypto';
import { mkdir, readdir, rename, rm, stat, unlink, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { RenderErrorCode, RenderStage } from './errors.js';

export type RunStatus =
  | 'initializing'
  | 'capturing'
  | 'resampling'
  | 'composing'
  | 'encoding'
  | 'validating'
  | 'completed'
  | 'failed'
  | 'aborted';

export interface RenderRunManifest {
  schemaVersion: 1;
  runId: string;
  status: RunStatus;
  planFile: string;
  configFile?: string;
  requestedOutput: string;
  startedAt: string;
  completedAt?: string;
  completedActions: number;
  totalActions: number;
  captureFrameCount?: number;
  outputFrameCount?: number;
  stages: Array<{
    stage: RenderStage;
    status: 'running' | 'completed' | 'failed' | 'aborted';
    startedAt: string;
    completedAt?: string;
    durationMs?: number;
  }>;
  failure?: {
    code: RenderErrorCode;
    message: string;
    stage: RenderStage;
    actionIndex?: number;
    actionKind?: string;
  };
}

export class RenderWorkspace {
  readonly runId =
    `${new Date().toISOString().replace(/[:.]/g, '-')}-${randomBytes(4).toString('hex')}`;
  readonly directory: string;
  readonly captureDirectory: string;
  readonly resampleDirectory: string;
  readonly compositionDirectory: string;
  readonly encodeDirectory: string;
  readonly diagnosticsDirectory: string;
  private manifest: RenderRunManifest;

  private constructor(root: string, manifest: RenderRunManifest) {
    this.directory = resolve(root, this.runId);
    this.captureDirectory = resolve(this.directory, 'capture');
    this.resampleDirectory = resolve(this.directory, 'resample');
    this.compositionDirectory = resolve(this.directory, 'composition');
    this.encodeDirectory = resolve(this.directory, 'encode');
    this.diagnosticsDirectory = resolve(this.directory, 'diagnostics');
    this.manifest = manifest;
  }

  static async create(options: {
    root: string;
    planFile: string;
    configFile?: string;
    output: string;
    actionCount: number;
  }): Promise<RenderWorkspace> {
    const seed: RenderRunManifest = {
      schemaVersion: 1,
      runId: '',
      status: 'initializing',
      planFile: resolve(options.planFile),
      ...(options.configFile ? { configFile: resolve(options.configFile) } : {}),
      requestedOutput: resolve(options.output),
      startedAt: new Date().toISOString(),
      completedActions: 0,
      totalActions: options.actionCount,
      stages: [],
    };
    const workspace = new RenderWorkspace(options.root, seed);
    workspace.manifest.runId = workspace.runId;
    await mkdir(workspace.captureDirectory, { recursive: true });
    await mkdir(workspace.resampleDirectory, { recursive: true });
    await mkdir(workspace.compositionDirectory, { recursive: true });
    await mkdir(workspace.encodeDirectory, { recursive: true });
    await mkdir(workspace.diagnosticsDirectory, { recursive: true });
    await workspace.update({});
    return workspace;
  }

  async update(update: Partial<RenderRunManifest>): Promise<void> {
    this.manifest = { ...this.manifest, ...update };
    const file = resolve(this.directory, 'run-manifest.json');
    const temporary = resolve(this.directory, '.run-manifest.json.tmp');
    await writeFile(temporary, `${JSON.stringify(this.manifest, null, 2)}\n`);
    await rename(temporary, file);
  }

  snapshot(): RenderRunManifest {
    return { ...this.manifest, stages: this.manifest.stages.map((stage) => ({ ...stage })) };
  }

  async startStage(stage: RenderStage, startedAt = new Date().toISOString()): Promise<void> {
    const stages = this.manifest.stages.filter(
      (entry) => entry.stage !== stage || entry.status !== 'running',
    );
    stages.push({ stage, status: 'running', startedAt });
    await this.update({ stages });
  }

  async finishStage(
    stage: RenderStage,
    status: 'completed' | 'failed' | 'aborted' = 'completed',
  ): Promise<void> {
    const completedAt = new Date().toISOString();
    const stages = this.manifest.stages.map((entry) =>
      entry.stage === stage && entry.status === 'running'
        ? {
            ...entry,
            status,
            completedAt,
            durationMs: Math.max(0, Date.parse(completedAt) - Date.parse(entry.startedAt)),
          }
        : entry,
    );
    await this.update({ stages });
  }

  async finishRunningStages(status: 'failed' | 'aborted'): Promise<void> {
    const completedAt = new Date().toISOString();
    await this.update({
      stages: this.manifest.stages.map((entry) =>
        entry.status === 'running'
          ? {
              ...entry,
              status,
              completedAt,
              durationMs: Math.max(0, Date.parse(completedAt) - Date.parse(entry.startedAt)),
            }
          : entry,
      ),
    });
  }

  async cleanup(): Promise<void> {
    await rm(this.directory, { recursive: true, force: true });
  }

  async removeOwnedStalePartials(minimumAgeMs = 60 * 60 * 1000): Promise<number> {
    let removed = 0;
    for (const entry of await readdir(this.encodeDirectory, { withFileTypes: true })) {
      if (!entry.isFile() || !/^\.[^.]+\.[0-9a-f]{16}\.partial\.mp4$/.test(entry.name)) continue;
      const file = resolve(this.encodeDirectory, entry.name);
      if (Date.now() - (await stat(file)).mtimeMs < minimumAgeMs) continue;
      await unlink(file);
      removed += 1;
    }
    return removed;
  }
}
