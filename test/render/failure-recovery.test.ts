import { access, mkdtemp, readdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { loadDemoPlan } from '../../src/plan/load.js';
import { renderDemo } from '../../src/render/render-demo.js';

describe('render failure recovery', () => {
  const originalOverride = process.env.SOREDEMO_FFMPEG_PATH;

  afterEach(() => {
    if (originalOverride === undefined) delete process.env.SOREDEMO_FFMPEG_PATH;
    else process.env.SOREDEMO_FFMPEG_PATH = originalOverride;
  });

  it('preserves stable diagnostics and removes signal listeners after preflight failure', async () => {
    const root = await mkdtemp(resolve(tmpdir(), 'soredemo-failure-'));
    const plan = await loadDemoPlan('test/fixtures/full-demo.yaml');
    const sigint = process.listenerCount('SIGINT');
    const sigterm = process.listenerCount('SIGTERM');
    process.env.SOREDEMO_FFMPEG_PATH = resolve(root, 'missing-ffmpeg');
    let workspace = '';
    for (let run = 0; run < 2; run += 1) {
      const output = resolve(root, `output-${run}.mp4`);
      try {
        await renderDemo({
          plan,
          planFile: 'test/fixtures/full-demo.yaml',
          configuration: {
            directory: root,
            viewport: { width: 1440, height: 900 },
            deviceScaleFactor: 2,
            output: { width: 1920, height: 1080, fps: 30 },
            runsDirectory: resolve(root, 'runs'),
          },
          outputPath: output,
          keepArtifacts: false,
        });
        throw new Error('expected render failure');
      } catch (error) {
        expect(error).toMatchObject({
          code: 'FFMPEG_NOT_FOUND',
          stage: 'preflight',
        });
        workspace = (error as { artifactsPath: string }).artifactsPath;
      }
      await expect(access(output)).rejects.toThrow();
    }
    expect(process.listenerCount('SIGINT')).toBe(sigint);
    expect(process.listenerCount('SIGTERM')).toBe(sigterm);
    const manifest = JSON.parse(await readFile(resolve(workspace, 'run-manifest.json'), 'utf8'));
    expect(manifest.status).toBe('failed');
    expect(manifest.stages.every((stage: { status: string }) => stage.status !== 'running')).toBe(
      true,
    );
    const diagnostic = JSON.parse(
      await readFile(resolve(workspace, 'diagnostics/error.json'), 'utf8'),
    );
    expect(diagnostic.error).toMatchObject({ code: 'FFMPEG_NOT_FOUND', stage: 'preflight' });
    expect(
      (await readdir(resolve(workspace, 'encode'))).some((file) => file.endsWith('.mp4')),
    ).toBe(false);
  });
});
