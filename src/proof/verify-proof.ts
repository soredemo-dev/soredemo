import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { ProofManifestSchema } from './schema.js';

export async function verifyProofBundle(directory: string): Promise<{
  valid: true;
  proofLevel: 'verified-live' | 'encoded-verified';
  manifestSha256: string;
}> {
  const source = await readFile(resolve(directory, 'manifest.json'), 'utf8');
  const manifest = ProofManifestSchema.parse(JSON.parse(source));
  for (const [file, expected] of Object.entries(manifest.files)) {
    if (file.includes('/') || file.includes('\\') || file === '..')
      throw new Error('Unsafe proof path');
    const actual = createHash('sha256')
      .update(await readFile(resolve(directory, file)))
      .digest('hex');
    if (actual !== expected) throw new Error(`Proof file hash mismatch: ${file}`);
  }
  return {
    valid: true,
    proofLevel: manifest.proofLevel,
    manifestSha256: createHash('sha256').update(source).digest('hex'),
  };
}
