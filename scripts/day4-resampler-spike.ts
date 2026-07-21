import { readFile, stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { openCaptureFrameReader } from '../src/resample/capture-frame-reader.js';
import {
  clickFrameMappingStatistics,
  mapEventToOutputFrame,
  nearestOutputIndex,
} from '../src/resample/event-frame-mapping.js';
import { resampleNearestFrames } from '../src/resample/nearest-frame-resampler.js';
import { OUTPUT_FPS, outputFrameCount } from '../src/resample/output-clock.js';
import { ResamplePlanWriter } from '../src/resample/resample-plan-writer.js';
import type {
  EventFrameMapping,
  ResampledFrameRecord,
  ResampleManifest,
} from '../src/resample/types.js';

interface TimelineClick {
  id: string;
  kind: 'click';
  mouseDownMs: number;
}

interface TimelineDocument {
  schemaVersion: 1;
  events: TimelineClick[];
}

const sourceCapturePath = resolve(process.argv[2] ?? '');
if (!process.argv[2]) throw new Error('Usage: day4-resampler-spike <capture-dir> [output-dir]');
const outputDirectory = resolve(process.argv[3] ?? '.tmp/day4-resampler-spike');

function parseTimeline(value: unknown): TimelineDocument {
  if (typeof value !== 'object' || value === null) throw new Error('Timeline must be an object');
  const document = value as TimelineDocument;
  if (document.schemaVersion !== 1 || !Array.isArray(document.events)) {
    throw new Error('Timeline schema is invalid');
  }
  if (
    document.events.length !== 30 ||
    document.events.some(
      (event) =>
        event.kind !== 'click' ||
        typeof event.id !== 'string' ||
        !Number.isFinite(event.mouseDownMs),
    )
  ) {
    throw new Error('Day-3 timeline must contain 30 valid click events');
  }
  return document;
}

async function artifactSizeBytes(): Promise<number> {
  const manifestSize = (await stat(resolve(outputDirectory, 'manifest.json'))).size;
  const framesSize = (await stat(resolve(outputDirectory, 'frames.jsonl'))).size;
  return manifestSize + framesSize;
}

const startedAt = performance.now();
const rssBeforeBytes = process.memoryUsage().rss;
let peakRssBytes = rssBeforeBytes;
const reader = await openCaptureFrameReader(sourceCapturePath);
const timeline = parseTimeline(
  JSON.parse(await readFile(resolve(sourceCapturePath, 'timeline.json'), 'utf8')),
);
const expectedOutputCount = outputFrameCount(reader.manifest.captureDurationMs, OUTPUT_FPS);
const clickOutputIndices = new Map<number, TimelineClick[]>();
for (const click of timeline.events) {
  const index = nearestOutputIndex(click.mouseDownMs, expectedOutputCount, OUTPUT_FPS);
  const clicks = clickOutputIndices.get(index) ?? [];
  clicks.push(click);
  clickOutputIndices.set(index, clicks);
}
const selectedClickFrames = new Map<string, ResampledFrameRecord>();
const writer = await ResamplePlanWriter.create(outputDirectory);
let outputRecordsWritten = 0;
try {
  const result = await resampleNearestFrames({
    sourceFrames: reader.frames(),
    fps: OUTPUT_FPS,
    onOutputFrame: async (record) => {
      await writer.writeFrame(record);
      outputRecordsWritten += 1;
      for (const click of clickOutputIndices.get(record.outputIndex) ?? []) {
        selectedClickFrames.set(click.id, record);
      }
    },
    onProgress: () => {
      if (outputRecordsWritten % 100 === 0) {
        peakRssBytes = Math.max(peakRssBytes, process.memoryUsage().rss);
      }
    },
  });
  peakRssBytes = Math.max(peakRssBytes, process.memoryUsage().rss);
  if (selectedClickFrames.size !== timeline.events.length) {
    throw new Error('Not every mouse-down event mapped to an output frame');
  }
  const manifest: ResampleManifest = {
    schemaVersion: 1,
    sourceCapturePath,
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
  await writer.close();

  const mappings: Array<EventFrameMapping & { clickId: string }> = timeline.events.map((click) => {
    const selectedFrame = selectedClickFrames.get(click.id);
    if (!selectedFrame) throw new Error(`Missing output selection for ${click.id}`);
    return {
      clickId: click.id,
      ...mapEventToOutputFrame({
        eventTimestampMs: click.mouseDownMs,
        outputFrameCount: result.outputFrameCount,
        selectedFrame,
        fps: OUTPUT_FPS,
      }),
    };
  });
  const selectedFrames = mappings.map((mapping) => {
    const selected = selectedClickFrames.get(mapping.clickId);
    if (!selected) throw new Error(`Missing selected source frame for ${mapping.clickId}`);
    return selected;
  });
  const clickStatistics = clickFrameMappingStatistics(mappings, selectedFrames);
  const clicksAbove20Ms = mappings.filter((mapping) => mapping.absoluteSourceToEventDeltaMs > 20);
  const rssAfterBytes = process.memoryUsage().rss;
  peakRssBytes = Math.max(peakRssBytes, rssAfterBytes);
  const executionDurationMs = performance.now() - startedAt;
  const outputArtifactSizeBytes = await artifactSizeBytes();
  const summary = {
    passed: true,
    sourceCapturePath,
    outputDirectory,
    sourceDurationMs: result.sourceDurationMs,
    sourceFrameCount: result.sourceFrameCount,
    outputFrameCount: result.outputFrameCount,
    firstOutputTimestampMs: 0,
    lastOutputTimestampMs: result.outputDurationMs,
    statistics: result.statistics,
    clickStatistics,
    clickMappings: mappings,
    clicksAbove20Ms,
    diagnostics: {
      executionDurationMs,
      rssBeforeBytes,
      rssAfterBytes,
      peakRssBytes,
      outputArtifactSizeBytes,
    },
  };
  process.stderr.write(
    [
      'Day 4 timestamp resampler',
      `source     ${result.sourceFrameCount} frames / ${result.sourceDurationMs.toFixed(3)}ms`,
      `output     ${result.outputFrameCount} frames / ${result.outputDurationMs.toFixed(3)}ms at 30fps`,
      `selection  median ${result.statistics.selectedSourceErrorMs.median.toFixed(3)}ms / p95 ${result.statistics.selectedSourceErrorMs.p95.toFixed(3)}ms / max ${result.statistics.selectedSourceErrorMs.max.toFixed(3)}ms`,
      `usage      ${result.statistics.sourceUsage.uniqueSourceFramesSelected} selected / ${result.statistics.sourceUsage.sourceFramesSkipped} skipped`,
      `clicks     ${clicksAbove20Ms.length} above 20ms source-to-mouse-down error`,
      'result     PASS',
      '',
    ].join('\n'),
  );
  process.stdout.write(`${JSON.stringify(summary)}\n`);
} finally {
  await writer.close();
}
