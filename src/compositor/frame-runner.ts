import type { ResampledFrameRecord } from '../resample/types.js';
import { BaseFrameCompositor } from './base-frame-compositor.js';
import type {
  CompositionFrameContext,
  CompositionRunSummary,
  FrameCompositor,
  FrameConsumer,
  SourceImageLoader,
} from './types.js';

export interface CompositionInput {
  frames: AsyncIterable<ResampledFrameRecord>;
  sourceWidth: number;
  sourceHeight: number;
  loader: SourceImageLoader;
  consumer: FrameConsumer;
  requireConsecutiveOutputIndices?: boolean;
  onFrameComplete?: (frameIndex: number) => void;
  compositor?: FrameCompositor;
}

export async function runComposition(input: CompositionInput): Promise<CompositionRunSummary> {
  const compositor =
    input.compositor ?? new BaseFrameCompositor(input.sourceWidth, input.sourceHeight);
  let previousOutputIndex: number | undefined;
  let framesProcessed = 0;
  let bytesProcessed = 0;
  let activeFrames = 0;
  let maxActiveFrames = 0;

  for await (const record of input.frames) {
    const expectedIndex = previousOutputIndex === undefined ? 0 : previousOutputIndex + 1;
    if (
      previousOutputIndex !== undefined &&
      (record.outputIndex <= previousOutputIndex ||
        (input.requireConsecutiveOutputIndices !== false && record.outputIndex !== expectedIndex))
    ) {
      throw new Error('Output records must be strictly ordered and consecutive');
    }
    if (
      previousOutputIndex === undefined &&
      input.requireConsecutiveOutputIndices !== false &&
      record.outputIndex !== 0
    ) {
      throw new Error('Full composition must begin at output index 0');
    }

    const image = await input.loader.load(record);
    // Source time selects browser pixels; output time evaluates composition metadata.
    const context: CompositionFrameContext = {
      outputIndex: record.outputIndex,
      outputTimestampMs: record.outputTimestampMs,
      sourceIndex: record.sourceIndex,
      sourceFile: record.sourceFile,
      sourceTimestampMs: record.sourceTimestampMs,
      signedSourceDeltaMs: record.signedSourceDeltaMs,
    };
    const frame = compositor.compose(context, image);
    activeFrames += 1;
    maxActiveFrames = Math.max(maxActiveFrames, activeFrames);
    try {
      await input.consumer.consume(frame);
    } finally {
      activeFrames -= 1;
    }
    framesProcessed += 1;
    bytesProcessed += frame.byteLength;
    previousOutputIndex = record.outputIndex;
    input.onFrameComplete?.(record.outputIndex);
  }

  return {
    framesProcessed,
    bytesProcessed,
    maxActiveFrames,
    sourceImages: input.loader.diagnostics(),
  };
}
