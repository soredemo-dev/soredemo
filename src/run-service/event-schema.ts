import { z } from 'zod';

export const RunEventSchema = z.strictObject({
  schemaVersion: z.literal(1),
  eventId: z.uuid(),
  runId: z.uuid(),
  sequence: z.number().int().positive(),
  type: z.string().min(1).max(100),
  producerTimestampMs: z.number().finite().nonnegative(),
  privacy: z.enum(['public', 'project-metadata', 'application-pixels', 'sensitive-local']),
  payload: z.record(z.string(), z.unknown()),
});
