import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { writeTimeline } from '../../src/capture/timeline-writer.js';

describe('writeTimeline', () => {
  it('writes deterministic newline-terminated timeline JSON', async () => {
    const outputDirectory = await mkdtemp(join(tmpdir(), 'soredemo-timeline-'));
    await writeTimeline(
      outputDirectory,
      {
        schemaVersion: 1,
        events: [
          {
            id: 'click-001',
            kind: 'click',
            startMs: 10,
            endMs: 40,
            target: { strategy: 'testId', value: { testId: 'static-target' } },
            targetBboxAtPathStart: { x: 20, y: 20, width: 100, height: 40 },
            targetBboxAtCommit: { x: 20, y: 20, width: 100, height: 40 },
            clickPoint: { x: 70, y: 40 },
            cursorPath: [
              { x: 0, y: 0, timeMs: 10 },
              { x: 70, y: 40, timeMs: 30 },
            ],
            mouseDownMs: 35,
            mouseUpMs: 40,
          },
        ],
      },
      50,
    );
    const contents = await readFile(join(outputDirectory, 'timeline.json'), 'utf8');
    expect(contents.endsWith('\n')).toBe(true);
    expect(JSON.parse(contents).events).toHaveLength(1);
  });
});
