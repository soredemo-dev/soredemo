import { createHash } from 'node:crypto';
import type { FileHandle } from 'node:fs/promises';
import { mkdir, open, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { BaseFrameCompositor } from './base-frame-compositor.js';
import { assertRawRgbaLayout } from './rgba.js';
import type {
  ComposedFrameHashRecord,
  CompositionManifest,
  FrameConsumer,
  RawRgbaFrame,
  SnapshotRecord,
} from './types.js';

const SHA256 = /^[a-f0-9]{64}$/;

export class DiagnosticFrameSink implements FrameConsumer {
  private expectedIndex = 0;
  private readonly rollingHash = createHash('sha256');
  private readonly snapshotRecords: SnapshotRecord[] = [];
  private closed = false;

  private constructor(
    private readonly outputDirectory: string,
    private readonly file: FileHandle,
    private readonly compositor: BaseFrameCompositor,
    private readonly snapshots: ReadonlyMap<number, string>,
  ) {}

  static async create(
    outputDirectory: string,
    compositor: BaseFrameCompositor,
    snapshots: ReadonlyMap<number, string> = new Map(),
  ): Promise<DiagnosticFrameSink> {
    await mkdir(resolve(outputDirectory, 'snapshots'), { recursive: true });
    const file = await open(resolve(outputDirectory, 'frame-hashes.jsonl'), 'wx');
    return new DiagnosticFrameSink(outputDirectory, file, compositor, snapshots);
  }

  async consume(frame: RawRgbaFrame): Promise<void> {
    if (this.closed) throw new Error('Diagnostic frame sink is closed');
    if (frame.outputIndex !== this.expectedIndex) {
      throw new Error(`Expected output frame ${this.expectedIndex}, received ${frame.outputIndex}`);
    }
    assertRawRgbaLayout(frame);
    const rgbaSha256 = createHash('sha256').update(frame.data).digest('hex');
    const record: ComposedFrameHashRecord = {
      outputIndex: frame.outputIndex,
      outputTimestampMs: frame.outputTimestampMs,
      sourceIndex: frame.sourceIndex,
      sourceTimestampMs: frame.sourceTimestampMs,
      rgbaSha256,
    };
    await this.file.write(`${JSON.stringify(record)}\n`);
    this.rollingHash.update(frame.data);

    const purpose = this.snapshots.get(frame.outputIndex);
    if (purpose) {
      const png = this.compositor.png();
      const name = `frame-${String(frame.outputIndex).padStart(6, '0')}.png`;
      const relativeFile = `snapshots/${name}`;
      const pngSha256 = createHash('sha256').update(png).digest('hex');
      await writeFile(resolve(this.outputDirectory, relativeFile), png, { flag: 'wx' });
      this.snapshotRecords.push({
        purpose,
        outputIndex: frame.outputIndex,
        outputTimestampMs: frame.outputTimestampMs,
        sourceIndex: frame.sourceIndex,
        sourceTimestampMs: frame.sourceTimestampMs,
        file: relativeFile,
        pngSha256,
      });
    }
    this.expectedIndex += 1;
  }

  async finish(): Promise<{
    frameCount: number;
    rollingRgbaSha256: string;
    snapshots: SnapshotRecord[];
  }> {
    if (this.closed) throw new Error('Diagnostic frame sink is already closed');
    this.closed = true;
    await this.file.close();
    return {
      frameCount: this.expectedIndex,
      rollingRgbaSha256: this.rollingHash.digest('hex'),
      snapshots: [...this.snapshotRecords],
    };
  }

  async abort(): Promise<void> {
    if (!this.closed) await this.file.close();
    this.closed = true;
  }
}

export async function writeCompositionManifest(
  outputDirectory: string,
  manifest: CompositionManifest,
): Promise<void> {
  if (!SHA256.test(manifest.rollingRgbaSha256)) {
    throw new Error('Composition manifest has an invalid rolling SHA-256');
  }
  await writeFile(
    resolve(outputDirectory, 'manifest.json'),
    `${JSON.stringify(manifest, null, 2)}\n`,
    { flag: 'wx' },
  );
}
