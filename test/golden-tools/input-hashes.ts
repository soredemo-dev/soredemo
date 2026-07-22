import { readFile } from 'node:fs/promises';
import { relative, resolve } from 'node:path';
import { sha256 } from './profile.js';
import { GoldenError } from './types.js';

export interface CanonicalInputManifest {
  schemaVersion: 1;
  sourceWidth: 2880;
  sourceHeight: 1800;
  outputFps: 30;
  frameCount: number;
  files: Record<string, string>;
}

export async function readCanonicalInputManifest(root: string): Promise<CanonicalInputManifest> {
  const value = JSON.parse(
    await readFile(resolve(root, 'manifest.json'), 'utf8'),
  ) as Partial<CanonicalInputManifest>;
  if (
    value.schemaVersion !== 1 ||
    value.sourceWidth !== 2880 ||
    value.sourceHeight !== 1800 ||
    value.outputFps !== 30 ||
    !Number.isInteger(value.frameCount) ||
    !value.files
  ) {
    throw new GoldenError('GOLDEN_MANIFEST_INVALID', 'Canonical input manifest is invalid');
  }
  return value as CanonicalInputManifest;
}

export async function hashCanonicalInputs(
  root: string,
  files: readonly string[],
): Promise<Record<string, string>> {
  const absoluteRoot = resolve(root);
  const output: Record<string, string> = {};
  for (const file of [...files].sort()) {
    const absolute = safeInputPath(absoluteRoot, file);
    output[file] = sha256(await readFile(absolute));
  }
  return output;
}

export async function verifyCanonicalInputHashes(
  root: string,
  manifest: CanonicalInputManifest,
): Promise<Record<string, string>> {
  const actual = await hashCanonicalInputs(root, Object.keys(manifest.files));
  const changed = Object.keys(manifest.files).filter(
    (file) => actual[file] !== manifest.files[file],
  );
  if (changed.length > 0) {
    throw new GoldenError('GOLDEN_INPUT_CHANGED', 'Canonical compositor inputs changed', {
      changed: changed.map((file) => ({
        file,
        expected: manifest.files[file],
        actual: actual[file],
      })),
    });
  }
  return actual;
}

export function safeInputPath(root: string, file: string): string {
  if (file.startsWith('/') || file.includes('\\')) {
    throw new GoldenError('GOLDEN_MANIFEST_INVALID', `Unsafe canonical path: ${file}`);
  }
  const absolute = resolve(root, file);
  if (absolute === root || relative(root, absolute).startsWith('..')) {
    throw new GoldenError('GOLDEN_MANIFEST_INVALID', `Canonical path escaped its root: ${file}`);
  }
  return absolute;
}
