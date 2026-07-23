import { EventEmitter } from 'node:events';
import { describe, expect, it } from 'vitest';
import { runCdpScreencast } from '../../src/capture/cdp-screencast.js';

describe('production capture preview hook', () => {
  it('uses the production CDP frame and acknowledges it before preview delivery', async () => {
    const order: string[] = [];
    const session = new EventEmitter() as EventEmitter & {
      send(method: string, payload?: unknown): Promise<void>;
      off(event: string, listener: (...args: never[]) => void): EventEmitter;
    };
    session.send = async (method) => {
      if (method === 'Page.startScreencast') {
        queueMicrotask(() =>
          session.emit('Page.screencastFrame', {
            data: Buffer.from('jpeg').toString('base64'),
            metadata: { timestamp: 1 },
            sessionId: 7,
          }),
        );
      }
      if (method === 'Page.screencastFrameAck') order.push('ack');
    };
    const diagnostics = {
      received: 0,
      acknowledged: 0,
      written: 0,
      highWaterMark: 0,
      overflowCount: 0,
      writeFailures: 0,
    };
    const writer = {
      diagnostics,
      markReceived() {
        diagnostics.received += 1;
      },
      markAcknowledged() {
        diagnostics.acknowledged += 1;
      },
      enqueue() {
        diagnostics.written += 1;
      },
    };
    await runCdpScreencast({
      session: session as never,
      writer: writer as never,
      durationMs: 1_000,
      startupCalibration: { browserEpochAtDriverZeroMs: 0, roundTripMs: 0, sampledAtDriverMs: 0 },
      settings: { format: 'jpeg', quality: 90, everyNthFrame: 1, maxWidth: 2880, maxHeight: 1800 },
      runDuringCapture: async () => undefined,
      tailDurationMs: 0,
      onPreviewFrame: (frame) => {
        order.push('preview');
        expect(frame.jpegBase64).toBe(Buffer.from('jpeg').toString('base64'));
      },
    });
    expect(order).toEqual(['ack', 'preview']);
  });
});
