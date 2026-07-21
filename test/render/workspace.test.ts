import { access, mkdtemp, readdir, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { RenderWorkspace } from '../../src/render/workspace.js';

describe('render workspace', () => {
  it('updates its manifest and removes only its own directory on cleanup', async () => {
    const root = await mkdtemp(resolve(tmpdir(), 'soredemo-runs-'));
    const workspace = await RenderWorkspace.create({
      root,
      planFile: 'demo.yaml',
      output: 'demo.mp4',
      actionCount: 6,
    });
    await workspace.update({ status: 'capturing', completedActions: 2 });
    expect(workspace.snapshot()).toMatchObject({ status: 'capturing', completedActions: 2 });
    await expect(access(workspace.compositionDirectory)).resolves.toBeUndefined();
    await workspace.cleanup();
    await expect(access(workspace.directory)).rejects.toThrow();
    expect(await readdir(root)).toEqual([]);
  });

  it('removes only old Soredemo-owned partial names inside the encode directory', async () => {
    const root = await mkdtemp(resolve(tmpdir(), 'soredemo-partials-'));
    const workspace = await RenderWorkspace.create({
      root,
      planFile: 'demo.yaml',
      output: 'demo.mp4',
      actionCount: 1,
    });
    const owned = resolve(workspace.encodeDirectory, '.demo.0123456789abcdef.partial.mp4');
    const unrelated = resolve(workspace.encodeDirectory, 'other.partial.mp4');
    await writeFile(owned, 'partial');
    await writeFile(unrelated, 'unrelated');
    const old = new Date(Date.now() - 2 * 60 * 60 * 1000);
    await utimes(owned, old, old);

    expect(await workspace.removeOwnedStalePartials()).toBe(1);
    expect(await readdir(workspace.encodeDirectory)).toEqual(['other.partial.mp4']);
  });
});
