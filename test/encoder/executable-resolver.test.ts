import { chmod, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { resolveExecutable, resolveFfprobe } from '../../src/encoder/executable-resolver.js';

async function executable(directory: string, name: string): Promise<string> {
  const file = join(directory, name);
  await writeFile(file, '#!/bin/sh\nexit 0\n');
  await chmod(file, 0o755);
  return file;
}

describe('executable resolver', () => {
  it.skipIf(process.platform === 'win32')(
    'resolves environment and sibling executables',
    async () => {
      const directory = await mkdtemp(join(tmpdir(), 'soredemo-encoder-resolver-'));
      const ffmpegFile = await executable(directory, 'custom ffmpeg');
      const ffprobeFile = await executable(directory, 'ffprobe');
      const ffmpeg = await resolveExecutable({
        name: 'ffmpeg',
        environmentVariable: 'SOREDEMO_FFMPEG_PATH',
        environment: { SOREDEMO_FFMPEG_PATH: ffmpegFile, PATH: '' },
      });
      expect(ffmpeg.source).toBe('environment');
      expect(ffmpeg.resolvedPath).toBe(ffmpegFile);
      expect((await resolveFfprobe(ffmpeg, { PATH: '' })).resolvedPath).toBe(ffprobeFile);
    },
  );

  it('rejects missing and empty overrides', async () => {
    await expect(
      resolveExecutable({
        name: 'ffmpeg',
        environmentVariable: 'SOREDEMO_FFMPEG_PATH',
        environment: { SOREDEMO_FFMPEG_PATH: '' },
      }),
    ).rejects.toThrow('must not be empty');
    await expect(resolveExecutable({ name: 'ffmpeg', environment: { PATH: '' } })).rejects.toThrow(
      'not found',
    );
  });
});
