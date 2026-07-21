import type { Stats } from 'node:fs';
import { lstat, realpath, stat } from 'node:fs/promises';
import { isAbsolute, relative, resolve } from 'node:path';
import { Image } from '@napi-rs/canvas';
import type { ResampledFrameRecord } from '../resample/types.js';
import type { SourceImageLoader, SourceImageLoaderDiagnostics } from './types.js';

function remainsInside(root: string, candidate: string): boolean {
  const path = relative(root, candidate);
  return (
    path !== '' &&
    path !== '..' &&
    !path.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) &&
    !isAbsolute(path)
  );
}

export class SequentialSourceImageLoader implements SourceImageLoader {
  private readonly currentImage = new Image();
  private currentSourceIndex: number | undefined;
  private previousSourceIndex: number | undefined;
  private readonly state: SourceImageLoaderDiagnostics = {
    decodeCount: 0,
    cacheHits: 0,
    cacheMisses: 0,
    maxDecodedImagesRetained: 0,
    outOfOrderSourceSelections: 0,
  };

  private constructor(
    private readonly captureDirectory: string,
    private readonly realCaptureDirectory: string,
    private readonly expectedWidth: number,
    private readonly expectedHeight: number,
  ) {}

  static async create(
    captureDirectory: string,
    expectedWidth: number,
    expectedHeight: number,
  ): Promise<SequentialSourceImageLoader> {
    const absolute = resolve(captureDirectory);
    return new SequentialSourceImageLoader(
      absolute,
      await realpath(absolute),
      expectedWidth,
      expectedHeight,
    );
  }

  async load(record: ResampledFrameRecord): Promise<Image> {
    if (this.previousSourceIndex !== undefined && record.sourceIndex < this.previousSourceIndex) {
      this.state.outOfOrderSourceSelections += 1;
      throw new Error('Source selections must be non-decreasing');
    }
    this.previousSourceIndex = record.sourceIndex;
    if (record.sourceIndex === this.currentSourceIndex) {
      this.state.cacheHits += 1;
      return this.currentImage;
    }

    const file = await this.resolveSourceFile(record.sourceFile);
    try {
      await this.decode(file);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`Unable to decode source image ${record.sourceFile}: ${message}`);
    }
    if (
      this.currentImage.width !== this.expectedWidth ||
      this.currentImage.height !== this.expectedHeight
    ) {
      throw new Error(
        `Decoded source dimensions ${this.currentImage.width}x${this.currentImage.height} do not match ${this.expectedWidth}x${this.expectedHeight}`,
      );
    }
    this.state.cacheMisses += 1;
    this.state.decodeCount += 1;
    this.currentSourceIndex = record.sourceIndex;
    this.state.maxDecodedImagesRetained = Math.max(this.state.maxDecodedImagesRetained, 1);
    return this.currentImage;
  }

  diagnostics(): SourceImageLoaderDiagnostics {
    return { ...this.state };
  }

  private async resolveSourceFile(sourceFile: string): Promise<string> {
    if (sourceFile.length === 0 || isAbsolute(sourceFile)) {
      throw new Error('Source image path must be a non-empty relative path');
    }
    const candidate = resolve(this.captureDirectory, sourceFile);
    if (!remainsInside(this.captureDirectory, candidate)) {
      throw new Error('Source image path escapes the capture directory');
    }
    let entry: Stats;
    try {
      entry = await lstat(candidate);
    } catch {
      throw new Error(`Source image is missing or unreadable: ${sourceFile}`);
    }
    if (entry.isSymbolicLink()) throw new Error('Source image must not be a symbolic link');
    const actual = await realpath(candidate);
    if (!remainsInside(this.realCaptureDirectory, actual)) {
      throw new Error('Source image resolves outside the capture directory');
    }
    const file = await stat(actual);
    if (!file.isFile()) throw new Error('Source image must be a regular file');
    return actual;
  }

  private async decode(file: string): Promise<void> {
    await new Promise<void>((resolveDecode, rejectDecode) => {
      this.currentImage.onload = () => {
        this.currentImage.decode().then(resolveDecode, rejectDecode);
      };
      this.currentImage.onerror = rejectDecode;
      this.currentImage.src = file;
    });
  }
}
