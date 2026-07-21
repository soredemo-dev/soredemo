import type { FileHandle } from 'node:fs/promises';
import { mkdir, open, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { ResampledFrameRecord, ResampleManifest } from './types.js';

export class ResamplePlanWriter {
  private frameFile: FileHandle | undefined;
  private written = 0;

  private constructor(private readonly outputDirectory: string) {}

  static async create(outputDirectory: string): Promise<ResamplePlanWriter> {
    await mkdir(outputDirectory, { recursive: true });
    const writer = new ResamplePlanWriter(outputDirectory);
    writer.frameFile = await open(resolve(outputDirectory, 'frames.jsonl'), 'wx');
    return writer;
  }

  async writeFrame(record: ResampledFrameRecord): Promise<void> {
    if (!this.frameFile) throw new Error('Resample plan writer is closed');
    if (record.outputIndex !== this.written) {
      throw new Error(`Expected output index ${this.written}, received ${record.outputIndex}`);
    }
    await this.frameFile.write(`${JSON.stringify(record)}\n`);
    this.written += 1;
  }

  async writeManifest(manifest: ResampleManifest): Promise<void> {
    if (manifest.outputFrameCount !== this.written) {
      throw new Error('Resample manifest count does not match written frame records');
    }
    await writeFile(
      resolve(this.outputDirectory, 'manifest.json'),
      `${JSON.stringify(manifest, null, 2)}\n`,
      { flag: 'wx' },
    );
  }

  async close(): Promise<void> {
    await this.frameFile?.close();
    this.frameFile = undefined;
  }
}
