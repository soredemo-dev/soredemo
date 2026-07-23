import { mkdir, stat } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';

export async function prepareProofPath(value: string): Promise<string> {
  const path = resolve(value);
  try {
    await stat(path);
    throw new Error(`OUTPUT_EXISTS: Proof output already exists: ${path}`);
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') {
      await mkdir(dirname(path), { recursive: true });
      return path;
    }
    throw error;
  }
}
