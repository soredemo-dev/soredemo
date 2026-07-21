import { createReadStream } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createInterface } from 'node:readline';
import type { ResampledFrameRecord, ResampleManifest } from '../resample/types.js';

export interface CompositionPlanReader {
  manifest: ResampleManifest;
  frames(): AsyncGenerator<ResampledFrameRecord>;
}

function record(value: unknown): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error('Resample record must be an object');
  }
  return value as Record<string, unknown>;
}

function finite(value: unknown, field: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error(`Resample field ${field} must be finite`);
  }
  return value;
}

function parseFrame(line: string, lineNumber: number): ResampledFrameRecord {
  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch {
    throw new Error(`Malformed resample frames.jsonl at line ${lineNumber}`);
  }
  const parsed = record(value);
  const relation = parsed.relation;
  const sourceFile = parsed.sourceFile;
  if (relation !== 'before' && relation !== 'exact' && relation !== 'after') {
    throw new Error(`Invalid relation at resample line ${lineNumber}`);
  }
  if (typeof sourceFile !== 'string' || sourceFile.length === 0) {
    throw new Error(`Invalid sourceFile at resample line ${lineNumber}`);
  }
  const outputIndex = finite(parsed.outputIndex, 'outputIndex');
  const sourceIndex = finite(parsed.sourceIndex, 'sourceIndex');
  if (!Number.isInteger(outputIndex) || outputIndex < 0) {
    throw new Error(`Invalid outputIndex at resample line ${lineNumber}`);
  }
  if (!Number.isInteger(sourceIndex) || sourceIndex < 1) {
    throw new Error(`Invalid sourceIndex at resample line ${lineNumber}`);
  }
  const result: ResampledFrameRecord = {
    outputIndex,
    outputTimestampMs: finite(parsed.outputTimestampMs, 'outputTimestampMs'),
    sourceIndex,
    sourceFile,
    sourceTimestampMs: finite(parsed.sourceTimestampMs, 'sourceTimestampMs'),
    signedSourceDeltaMs: finite(parsed.signedSourceDeltaMs, 'signedSourceDeltaMs'),
    absoluteSourceDeltaMs: finite(parsed.absoluteSourceDeltaMs, 'absoluteSourceDeltaMs'),
    relation,
  };
  const expectedRelation =
    result.signedSourceDeltaMs < 0 ? 'before' : result.signedSourceDeltaMs > 0 ? 'after' : 'exact';
  if (expectedRelation !== result.relation)
    throw new Error('Resample relation does not match delta');
  return result;
}

function parseManifest(value: unknown): ResampleManifest {
  const parsed = record(value) as unknown as ResampleManifest;
  if (
    parsed.schemaVersion !== 1 ||
    parsed.outputFps !== 30 ||
    !Number.isInteger(parsed.outputFrameCount) ||
    parsed.outputFrameCount < 1 ||
    parsed.sourcePixelWidth !== 2880 ||
    parsed.sourcePixelHeight !== 1800 ||
    parsed.selectionPolicy !== 'nearest-timestamp' ||
    parsed.tieBreakPolicy !== 'earlier-frame'
  ) {
    throw new Error('Resample manifest violates the Day-4 plan contract');
  }
  return parsed;
}

export async function openCompositionPlan(planDirectory: string): Promise<CompositionPlanReader> {
  const absolute = resolve(planDirectory);
  let manifest: ResampleManifest;
  try {
    manifest = parseManifest(
      JSON.parse(await readFile(resolve(absolute, 'manifest.json'), 'utf8')),
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Unable to read resample manifest: ${message}`);
  }

  let consumed = false;
  return {
    manifest,
    async *frames() {
      if (consumed) throw new Error('Composition plan reader can only be consumed once');
      consumed = true;
      const input = createReadStream(resolve(absolute, 'frames.jsonl'), { encoding: 'utf8' });
      const lines = createInterface({ input, crlfDelay: Number.POSITIVE_INFINITY });
      let expectedIndex = 0;
      let previousSourceIndex: number | undefined;
      for await (const line of lines) {
        if (line.length === 0)
          throw new Error(`Empty resample record at line ${expectedIndex + 1}`);
        const frame = parseFrame(line, expectedIndex + 1);
        if (frame.outputIndex !== expectedIndex) {
          throw new Error(`Expected output index ${expectedIndex}, received ${frame.outputIndex}`);
        }
        const expectedTimestamp = (frame.outputIndex * 1000) / manifest.outputFps;
        if (frame.outputTimestampMs !== expectedTimestamp) {
          throw new Error(`Output timestamp mismatch at index ${frame.outputIndex}`);
        }
        if (previousSourceIndex !== undefined && frame.sourceIndex < previousSourceIndex) {
          throw new Error('Resample source selections are out of order');
        }
        previousSourceIndex = frame.sourceIndex;
        expectedIndex += 1;
        yield frame;
      }
      if (expectedIndex !== manifest.outputFrameCount) {
        throw new Error(
          `Resample manifest count ${manifest.outputFrameCount} does not match ${expectedIndex} records`,
        );
      }
    },
  };
}
