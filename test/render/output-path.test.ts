import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { defaultOutputPath, prepareOutputPath } from '../../src/render/output-path.js';

describe('render output paths', () => {
  it('derives an MP4 beside the Demo Plan', () => {
    expect(defaultOutputPath('/project/demos/create-project.yaml')).toBe(
      '/project/demos/create-project.mp4',
    );
  });

  it('creates the parent and refuses existing files and directories', async () => {
    const root = await mkdtemp(resolve(tmpdir(), 'soredemo-output-'));
    const output = resolve(root, 'nested/demo.mp4');
    await expect(prepareOutputPath(resolve(root, 'demo.yaml'), output)).resolves.toBe(output);
    await writeFile(output, 'existing');
    await expect(prepareOutputPath(resolve(root, 'demo.yaml'), output)).rejects.toThrow(
      'already exists',
    );
    const directory = resolve(root, 'directory');
    await mkdir(directory);
    await expect(prepareOutputPath(resolve(root, 'demo.yaml'), directory)).rejects.toThrow(
      'is a directory',
    );
  });
});
