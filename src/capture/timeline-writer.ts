import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { TimelineDocument } from '../timeline/types.js';
import { validateTimelineDocument } from '../timeline/validation.js';

export async function writeTimeline(
  outputDirectory: string,
  document: TimelineDocument,
  captureDurationMs?: number,
): Promise<void> {
  validateTimelineDocument(document, captureDurationMs);
  await writeFile(
    resolve(outputDirectory, 'timeline.json'),
    `${JSON.stringify(document, null, 2)}\n`,
    { flag: 'wx' },
  );
}
