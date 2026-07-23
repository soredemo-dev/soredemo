import { randomUUID } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import type { RunEvent } from './types.js';

export class RunEventJournal {
  private sequence = 0;
  private readonly events: RunEvent[] = [];
  private readonly listeners = new Set<(event: RunEvent) => void>();

  constructor(
    readonly runId: string,
    readonly maximumEvents = 2_048,
  ) {}

  publish(
    type: string,
    payload: Record<string, unknown>,
    privacy: RunEvent['privacy'] = 'project-metadata',
    options: { ephemeral?: boolean } = {},
  ): RunEvent {
    const event: RunEvent = {
      schemaVersion: 1,
      eventId: randomUUID(),
      runId: this.runId,
      sequence: ++this.sequence,
      type,
      producerTimestampMs: performance.now(),
      privacy,
      payload,
    };
    if (!options.ephemeral) {
      this.events.push(event);
      if (this.events.length > this.maximumEvents)
        this.events.splice(0, this.events.length - this.maximumEvents);
    }
    for (const listener of this.listeners) queueMicrotask(() => listener(event));
    return event;
  }

  after(sequence: number): RunEvent[] {
    return this.events.filter((event) => event.sequence > sequence);
  }

  subscribe(listener: (event: RunEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  get lastSequence(): number {
    return this.sequence;
  }
}
