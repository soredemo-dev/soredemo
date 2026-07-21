import { type ChildProcessWithoutNullStreams, spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { createReadStream, createWriteStream, type WriteStream } from 'node:fs';
import { access, mkdir, open, rename, stat, unlink } from 'node:fs/promises';
import { basename, dirname, extname, join, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { assertRawRgbaLayout } from '../compositor/rgba.js';
import type { RawRgbaFrame } from '../compositor/types.js';
import { latencyStatistics } from './encoding-statistics.js';
import { ffmpegArguments, validateEncodingConfig } from './ffmpeg-arguments.js';
import type {
  EncodedVideoResult,
  EncoderBackpressureStatistics,
  EncoderSession,
  ResolvedExecutable,
  VideoEncodingConfig,
} from './types.js';

interface ProcessOutcome {
  exitCode: number;
  signal: NodeJS.Signals | null;
}

export interface FfmpegEncoderOptions {
  executable: ResolvedExecutable;
  config: VideoEncodingConfig;
  logPath: string;
  validateTemporary: (file: string) => Promise<void>;
  shutdownTimeoutMs?: number;
  stderrTailBytes?: number;
}

export class FfmpegEncoder implements EncoderSession {
  readonly temporaryOutputPath: string;
  readonly childPid: number | undefined;
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly log: WriteStream;
  private readonly outcome: Promise<ProcessOutcome>;
  private readonly startedAt = performance.now();
  private readonly writeLatencies: number[] = [];
  private readonly stats = {
    framesWritten: 0,
    writeFalseCount: 0,
    drainCount: 0,
    maxPendingFrames: 0,
    maxPendingBytes: 0,
  };
  private pendingFrames = 0;
  private expectedIndex = 0;
  private state: 'open' | 'finalizing' | 'finalized' | 'aborted' = 'open';
  private stderrTail = Buffer.alloc(0);
  private processError: Error | undefined;
  private logClosed = false;

  private constructor(
    private readonly options: FfmpegEncoderOptions,
    temporaryOutputPath: string,
  ) {
    this.temporaryOutputPath = temporaryOutputPath;
    this.log = createWriteStream(options.logPath, { flags: 'wx' });
    this.child = spawn(
      options.executable.resolvedPath,
      ffmpegArguments(options.config, temporaryOutputPath),
      { shell: false, stdio: ['pipe', 'pipe', 'pipe'] },
    );
    this.childPid = this.child.pid;
    this.child.stdout.resume();
    this.child.stderr.on('data', (chunk: Buffer) => this.captureStderr(chunk));
    this.outcome = new Promise((resolveOutcome) => {
      this.child.once('error', (error) => {
        this.processError = error;
      });
      this.child.once('close', (exitCode, signal) => {
        resolveOutcome({ exitCode: exitCode ?? -1, signal });
      });
    });
  }

  static async create(options: FfmpegEncoderOptions): Promise<FfmpegEncoder> {
    validateEncodingConfig(options.config);
    const output = resolve(options.config.outputPath);
    await mkdir(dirname(output), { recursive: true });
    if (!options.config.overwrite) {
      try {
        await access(output);
        throw new Error(`Output already exists: ${output}`);
      } catch (error) {
        if (error instanceof Error && error.message.startsWith('Output already exists:'))
          throw error;
      }
    }
    const extension = extname(output) || '.mp4';
    const stem = basename(output, extension);
    const temporary = join(
      dirname(output),
      `.${stem}.${randomBytes(8).toString('hex')}.partial${extension}`,
    );
    return new FfmpegEncoder(
      { ...options, config: { ...options.config, outputPath: output } },
      temporary,
    );
  }

  async consume(frame: RawRgbaFrame): Promise<void> {
    if (this.state !== 'open')
      throw new Error(`Cannot consume frame after encoder is ${this.state}`);
    if (this.expectedIndex >= this.options.config.expectedFrameCount) {
      throw new Error('Encoder received more frames than configured');
    }
    assertRawRgbaLayout(frame);
    if (frame.width !== this.options.config.width || frame.height !== this.options.config.height) {
      throw new Error('RGBA frame dimensions do not match encoder configuration');
    }
    if (frame.outputIndex !== this.expectedIndex) {
      throw new Error(
        `Expected encoder frame ${this.expectedIndex}, received ${frame.outputIndex}`,
      );
    }
    const expectedTimestamp = (frame.outputIndex * 1000) / this.options.config.fps;
    if (Math.abs(frame.outputTimestampMs - expectedTimestamp) > 1e-7) {
      throw new Error(`Frame ${frame.outputIndex} is not on the fixed output clock`);
    }
    if (this.processError) throw this.processError;

    const startedAt = performance.now();
    this.pendingFrames += 1;
    this.stats.maxPendingFrames = Math.max(this.stats.maxPendingFrames, this.pendingFrames);
    this.stats.maxPendingBytes = Math.max(
      this.stats.maxPendingBytes,
      this.pendingFrames * frame.byteLength,
    );
    try {
      let callbackResolve: (() => void) | undefined;
      let callbackReject: ((error: Error) => void) | undefined;
      const callback = new Promise<void>((resolveWrite, rejectWrite) => {
        callbackResolve = resolveWrite;
        callbackReject = rejectWrite;
      });
      const accepted = this.child.stdin.write(frame.data, (error) => {
        if (error) callbackReject?.(error);
        else callbackResolve?.();
      });
      const drains: Promise<void>[] = [];
      if (!accepted) {
        this.stats.writeFalseCount += 1;
        drains.push(
          new Promise<void>((resolveDrain, rejectDrain) => {
            const onDrain = () => {
              cleanup();
              this.stats.drainCount += 1;
              resolveDrain();
            };
            const onError = (error: Error) => {
              cleanup();
              rejectDrain(error);
            };
            const cleanup = () => {
              this.child.stdin.off('drain', onDrain);
              this.child.stdin.off('error', onError);
            };
            this.child.stdin.once('drain', onDrain);
            this.child.stdin.once('error', onError);
          }),
        );
      }
      await Promise.all([callback, ...drains]);
      this.stats.framesWritten += 1;
      this.expectedIndex += 1;
      this.writeLatencies.push(performance.now() - startedAt);
    } catch (error) {
      const outcome = await Promise.race([this.outcome, Promise.resolve(undefined)]);
      if (outcome && outcome.exitCode !== 0) {
        throw new Error(
          `FFmpeg exited early with code ${outcome.exitCode}: ${this.stderrTail.toString('utf8')}`,
          { cause: error },
        );
      }
      throw error;
    } finally {
      this.pendingFrames -= 1;
    }
  }

  async finalize(): Promise<EncodedVideoResult> {
    if (this.state !== 'open') throw new Error(`Cannot finalize encoder after it is ${this.state}`);
    this.state = 'finalizing';
    if (this.expectedIndex !== this.options.config.expectedFrameCount) {
      const error = new Error(
        `Encoder received ${this.expectedIndex} of ${this.options.config.expectedFrameCount} frames`,
      );
      await this.abortInternal();
      throw error;
    }
    await new Promise<void>((resolveEnd, rejectEnd) => {
      this.child.stdin.end((error?: Error | null) => {
        if (error) rejectEnd(error);
        else resolveEnd();
      });
    });
    const outcome = await this.outcome;
    await this.closeLog();
    if (this.processError) {
      await this.removeTemporary();
      this.state = 'aborted';
      throw this.processError;
    }
    if (outcome.exitCode !== 0) {
      await this.removeTemporary();
      this.state = 'aborted';
      throw new Error(
        `FFmpeg failed with code ${outcome.exitCode} signal ${outcome.signal ?? 'none'}: ${this.stderrTail.toString('utf8')}`,
      );
    }
    try {
      await this.options.validateTemporary(this.temporaryOutputPath);
      const handle = await open(this.temporaryOutputPath, 'r+');
      await handle.sync();
      await handle.close();
      await rename(this.temporaryOutputPath, this.options.config.outputPath);
      const output = await stat(this.options.config.outputPath);
      const hash = createHash('sha256');
      for await (const chunk of createReadStream(this.options.config.outputPath)) {
        hash.update(chunk as Buffer);
      }
      this.state = 'finalized';
      return {
        outputPath: this.options.config.outputPath,
        frameCount: this.expectedIndex,
        byteLength: output.size,
        sha256: hash.digest('hex'),
        executionMs: performance.now() - this.startedAt,
        ffmpegExitCode: outcome.exitCode,
        ffmpegSignal: outcome.signal,
        backpressure: this.backpressure(),
      };
    } catch (error) {
      await this.removeTemporary();
      this.state = 'aborted';
      throw error;
    }
  }

  async abort(_reason: unknown): Promise<void> {
    if (this.state === 'finalized' || this.state === 'aborted') return;
    this.state = 'aborted';
    await this.abortInternal();
  }

  stderrTailText(): string {
    return this.stderrTail.toString('utf8');
  }

  backpressure(): EncoderBackpressureStatistics {
    return { ...this.stats, writeLatencyMs: latencyStatistics(this.writeLatencies) };
  }

  private captureStderr(chunk: Buffer): void {
    if (!this.log.write(chunk)) {
      this.child.stderr.pause();
      this.log.once('drain', () => this.child.stderr.resume());
    }
    const limit = this.options.stderrTailBytes ?? 64 * 1024;
    this.stderrTail = Buffer.concat([this.stderrTail, chunk]);
    if (this.stderrTail.byteLength > limit) {
      this.stderrTail = this.stderrTail.subarray(this.stderrTail.byteLength - limit);
    }
  }

  private async abortInternal(): Promise<void> {
    this.child.stdin.destroy();
    const graceful = this.outcome.then(() => true);
    this.child.kill('SIGTERM');
    const timeoutMs = this.options.shutdownTimeoutMs ?? 2_000;
    const exited = await Promise.race([
      graceful,
      new Promise<false>((resolveTimeout) => setTimeout(() => resolveTimeout(false), timeoutMs)),
    ]);
    if (!exited) {
      this.child.kill('SIGKILL');
      await this.outcome;
    }
    await this.closeLog();
    await this.removeTemporary();
  }

  private async closeLog(): Promise<void> {
    if (this.logClosed) return;
    this.logClosed = true;
    await new Promise<void>((resolveClose, rejectClose) => {
      this.log.once('error', rejectClose);
      this.log.end(resolveClose);
    });
  }

  private async removeTemporary(): Promise<void> {
    try {
      await unlink(this.temporaryOutputPath);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
    }
  }
}
