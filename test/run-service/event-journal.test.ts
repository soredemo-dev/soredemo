import { describe, expect, it } from 'vitest';
import { RunEventJournal } from '../../src/run-service/event-journal.js';
import { RunEventSchema } from '../../src/run-service/event-schema.js';
import { assertRunTransition } from '../../src/run-service/run-coordinator.js';

describe('run service events and state', () => {
  it('enforces legal state transitions and terminal immutability', () => {
    expect(() => assertRunTransition('created', 'validating')).not.toThrow();
    expect(() => assertRunTransition('completed', 'capturing')).toThrow('Illegal run transition');
    expect(() => assertRunTransition('failed', 'ready')).toThrow('Illegal run transition');
  });

  it('orders events, replays after a sequence, and bounds the durable journal', () => {
    const journal = new RunEventJournal('00000000-0000-4000-8000-000000000001', 3);
    for (let index = 0; index < 5; index += 1) journal.publish('action.completed', { index });
    const replay = journal.after(2);
    expect(replay.map((event) => event.sequence)).toEqual([3, 4, 5]);
    expect(replay.every((event) => RunEventSchema.safeParse(event).success)).toBe(true);
    const preview = journal.publish(
      'capture.preview',
      { jpegBase64: 'not-retained' },
      'application-pixels',
      { ephemeral: true },
    );
    expect(journal.after(5)).toEqual([]);
    expect(preview.sequence).toBe(6);
  });
});
