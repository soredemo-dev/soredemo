import { mkdir, stat } from 'node:fs/promises';
import { basename, dirname, extname, resolve } from 'node:path';

export function defaultOutputPath(planFile: string): string {
  const absolute = resolve(planFile);
  const extension = extname(absolute);
  const stem = basename(absolute, extension);
  return resolve(dirname(absolute), `${stem}.mp4`);
}

export async function prepareOutputPath(planFile: string, requested?: string): Promise<string> {
  const output = requested ? resolve(requested) : defaultOutputPath(planFile);
  try {
    const entry = await stat(output);
    if (entry.isDirectory()) throw new Error(`Output path is a directory: ${output}`);
    throw new Error(`Output already exists: ${output}`);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
  }
  await mkdir(dirname(output), { recursive: true });
  return output;
}
