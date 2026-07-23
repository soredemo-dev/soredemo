import { z } from 'zod';

const Sha256 = z.string().regex(/^[a-f0-9]{64}$/u);

export const ProofManifestSchema = z.strictObject({
  schemaVersion: z.literal(1),
  producer: z.strictObject({
    name: z.literal('soredemo'),
    version: z.string().min(1),
  }),
  proofLevel: z.enum(['verified-live', 'encoded-verified']),
  planSha256: Sha256,
  configSha256: Sha256,
  outputMp4Sha256: Sha256,
  files: z.record(z.string(), Sha256),
  completed: z.literal(true),
});

export type ProofManifest = z.infer<typeof ProofManifestSchema>;
