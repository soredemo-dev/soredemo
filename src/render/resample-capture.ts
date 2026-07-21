import { openCaptureFrameReader } from '../resample/capture-frame-reader.js';
import { resampleNearestFrames } from '../resample/nearest-frame-resampler.js';
import { OUTPUT_FPS } from '../resample/output-clock.js';
import { ResamplePlanWriter } from '../resample/resample-plan-writer.js';
import type { ResampleManifest } from '../resample/types.js';

export async function resampleCapture(
  captureDirectory: string,
  outputDirectory: string,
): Promise<ResampleManifest> {
  const reader = await openCaptureFrameReader(captureDirectory);
  const writer = await ResamplePlanWriter.create(outputDirectory);
  try {
    const result = await resampleNearestFrames({
      sourceFrames: reader.frames(),
      fps: OUTPUT_FPS,
      onOutputFrame: (record) => writer.writeFrame(record),
    });
    const manifest: ResampleManifest = {
      schemaVersion: 1,
      sourceCapturePath: captureDirectory,
      sourceCaptureSchemaVersion: reader.manifest.schemaVersion,
      sourceFrameCount: result.sourceFrameCount,
      sourceDurationMs: result.sourceDurationMs,
      sourcePixelWidth: result.sourcePixelWidth,
      sourcePixelHeight: result.sourcePixelHeight,
      outputFps: OUTPUT_FPS,
      outputFrameCount: result.outputFrameCount,
      outputDurationMs: result.outputDurationMs,
      selectionPolicy: 'nearest-timestamp',
      tieBreakPolicy: 'earlier-frame',
      statistics: result.statistics,
    };
    await writer.writeManifest(manifest);
    return manifest;
  } finally {
    await writer.close();
  }
}
