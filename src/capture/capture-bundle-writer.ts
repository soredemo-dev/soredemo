import type { FileHandle } from 'node:fs/promises';
import { mkdir, open, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { readJpegDimensions } from './jpeg-dimensions.js';
import type {
  CapturedFrameRecord,
  CaptureManifest,
  CaptureQueueDiagnostics,
  QueuedCaptureFrame,
} from './types.js';

export interface CaptureBundleWriterOptions {
  outputDirectory: string;
  queueLimit: number;
  onFailure?: (error: Error) => void;
}

export class CaptureBundleWriter {
  readonly records: CapturedFrameRecord[] = [];
  readonly diagnostics: CaptureQueueDiagnostics = {
    received: 0,
    acknowledged: 0,
    written: 0,
    highWaterMark: 0,
    overflowCount: 0,
    writeFailures: 0,
  };

  private readonly queue: QueuedCaptureFrame[] = [];
  private draining = false;
  private writing = false;
  private closed = false;
  private failure: Error | undefined;
  private drainPromise: Promise<void> | undefined;
  private framesFile: FileHandle | undefined;

  private constructor(private readonly options: CaptureBundleWriterOptions) {}

  static async create(options: CaptureBundleWriterOptions): Promise<CaptureBundleWriter> {
    if (!Number.isInteger(options.queueLimit) || options.queueLimit < 1) {
      throw new Error('Capture queue limit must be a positive integer');
    }
    const writer = new CaptureBundleWriter(options);
    await mkdir(resolve(options.outputDirectory, 'frames'), { recursive: true });
    writer.framesFile = await open(resolve(options.outputDirectory, 'frames.jsonl'), 'wx');
    return writer;
  }

  markReceived(): void {
    this.diagnostics.received += 1;
  }

  markAcknowledged(): void {
    this.diagnostics.acknowledged += 1;
  }

  enqueue(frame: QueuedCaptureFrame): void {
    if (this.closed) throw new Error('Capture bundle writer is closed');
    if (this.failure) throw this.failure;
    const outstanding = this.queue.length + (this.writing ? 1 : 0);
    if (outstanding >= this.options.queueLimit) {
      this.diagnostics.overflowCount += 1;
      throw new Error(`Capture queue exceeded its limit of ${this.options.queueLimit}`);
    }

    this.queue.push(frame);
    this.diagnostics.highWaterMark = Math.max(
      this.diagnostics.highWaterMark,
      this.queue.length + (this.writing ? 1 : 0),
    );
    if (!this.draining) {
      this.draining = true;
      this.drainPromise = this.drain().catch((error: unknown) => {
        const failure = error instanceof Error ? error : new Error(String(error));
        this.failure = failure;
        this.diagnostics.writeFailures += 1;
        this.options.onFailure?.(failure);
      });
    }
  }

  async close(): Promise<void> {
    this.closed = true;
    await this.drainPromise;
    await this.framesFile?.close();
    this.framesFile = undefined;
    if (this.failure) throw this.failure;
    if (this.queue.length !== 0 || this.writing) {
      throw new Error('Capture bundle writer closed before its queue drained');
    }
  }

  async writeManifest(manifest: CaptureManifest): Promise<void> {
    await writeFile(
      resolve(this.options.outputDirectory, 'manifest.json'),
      `${JSON.stringify(manifest, null, 2)}\n`,
      { flag: 'wx' },
    );
  }

  private async drain(): Promise<void> {
    try {
      while (this.queue.length > 0) {
        const frame = this.queue.shift();
        if (!frame) continue;
        this.writing = true;
        await this.writeFrame(frame);
        this.writing = false;
      }
    } finally {
      this.writing = false;
      this.draining = false;
    }
  }

  private async writeFrame(frame: QueuedCaptureFrame): Promise<void> {
    const filename = `${String(frame.index).padStart(6, '0')}.jpg`;
    const relativeFile = `frames/${filename}`;
    const dimensions = readJpegDimensions(frame.data);
    await writeFile(resolve(this.options.outputDirectory, relativeFile), frame.data, {
      flag: 'wx',
    });

    const record: CapturedFrameRecord = {
      index: frame.index,
      file: relativeFile,
      timestampMs: frame.timestampMs,
      pixelWidth: dimensions.width,
      pixelHeight: dimensions.height,
      pageScaleFactor: frame.metadata.pageScaleFactor,
      scrollOffsetX: frame.metadata.scrollOffsetX,
      scrollOffsetY: frame.metadata.scrollOffsetY,
      offsetTop: frame.metadata.offsetTop,
      receivedAtMs: frame.receivedAtMs,
    };
    await this.framesFile?.write(`${JSON.stringify(record)}\n`);
    this.records.push(record);
    this.diagnostics.written += 1;
  }
}
