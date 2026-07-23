import { realpath, stat } from 'node:fs/promises';
import { relative, resolve, sep } from 'node:path';
import { StudioError } from './errors.js';

export interface RegisteredArtifact {
  id: string;
  runId: string;
  kind: 'mp4' | 'proof' | 'diagnostic';
  path: string;
  mimeType: string;
}

function inside(root: string, candidate: string): boolean {
  const local = relative(root, candidate);
  return (
    local === '' || (local !== '..' && !local.startsWith(`..${sep}`) && !local.startsWith(sep))
  );
}

export class ArtifactRegistry {
  private readonly entries = new Map<string, RegisteredArtifact>();

  constructor(
    private readonly projectRoot: string,
    private readonly runRoots: string[] = [],
  ) {}

  async register(entry: RegisteredArtifact): Promise<void> {
    const absolute = resolve(entry.path);
    const resolved = await realpath(absolute);
    const allowedRoots = [
      await realpath(this.projectRoot),
      ...this.runRoots.map((root) => resolve(root)),
    ];
    if (!allowedRoots.some((root) => inside(root, resolved))) {
      throw new StudioError('STUDIO_PATH_INVALID', 'Artifact escaped the project or run workspace');
    }
    if (!(await stat(resolved)).isFile() && entry.kind !== 'proof') {
      throw new StudioError('STUDIO_ARTIFACT_NOT_FOUND', 'Artifact is not a regular file', 404);
    }
    this.entries.set(entry.id, { ...entry, path: resolved });
  }

  get(id: string): RegisteredArtifact {
    const entry = this.entries.get(id);
    if (!entry)
      throw new StudioError('STUDIO_ARTIFACT_NOT_FOUND', 'Artifact is not registered', 404);
    return entry;
  }

  list(runId: string): RegisteredArtifact[] {
    return [...this.entries.values()].filter((entry) => entry.runId === runId);
  }
}
