import { createHash } from 'node:crypto';
import { mkdir, readdir, readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { captureSession } from '../src/capture/capture-session.js';
import {
  type RecordedClickDiagnostics,
  recordFixtureClick,
} from '../src/capture/click-recorder.js';
import {
  analyzeMouseDownFrameWindow,
  type MouseDownFrameWindow,
} from '../src/capture/frame-cadence.js';
import { summarizeDistribution } from '../src/capture/gate-statistics.js';
import {
  browserEpochToCaptureTimeMs,
  hideBrowserCursor,
  installPageInstrumentation,
} from '../src/capture/page-instrumentation.js';
import { writeTimeline } from '../src/capture/timeline-writer.js';
import type { CapturedFrameRecord } from '../src/capture/types.js';
import type { ClickTimelineEvent, TimelineDocument } from '../src/timeline/types.js';
import { validateTimelineDocument } from '../src/timeline/validation.js';
import { startFixtureServer } from '../test/fixtures/web-app/server.js';

interface ClickGateRecord {
  event: ClickTimelineEvent;
  diagnostics: RecordedClickDiagnostics;
  frameWindow?: MouseDownFrameWindow;
}

interface Day3GateSummary {
  passed: boolean;
  clickCount: number;
  staticClicks: number;
  hoverClicks: number;
  applicationClicksObserved: number;
  pointerDownEventsObserved: number;
  clickEventsObserved: number;
  pathPoints: ReturnType<typeof summarizeDistribution>;
  mouseMoveRoundTripMs: Omit<ReturnType<typeof summarizeDistribution>, 'min'>;
  pointerDownCoordinateErrorCssPx: Omit<ReturnType<typeof summarizeDistribution>, 'min'>;
  targetBboxChangeCssPx: Omit<ReturnType<typeof summarizeDistribution>, 'min'>;
  mouseDownFrameWindow: {
    maxGapMs: number;
    p95MaxGapMs: number;
    worstClickId: string;
    worstNearestFrameDistanceMs: number;
  };
  capture: {
    frameCount: number;
    sourcePixelWidth: number;
    sourcePixelHeight: number;
    received: number;
    acknowledged: number;
    written: number;
    queueHighWaterMark: number;
    queueOverflows: number;
  };
}

const fixtureDirectory = resolve('test/fixtures/web-app');
const outputDirectory = resolve(
  '.tmp/day3-click-gate',
  new Date().toISOString().replaceAll(':', '-').replaceAll('.', '-'),
  '.capture',
);

async function fixtureHash(): Promise<string> {
  const hash = createHash('sha256');
  for (const file of ['index.html', 'styles.css', 'app.js']) {
    hash.update(await readFile(resolve(fixtureDirectory, file)));
  }
  return hash.digest('hex');
}

async function verifyBundle(
  records: CapturedFrameRecord[],
  timeline: TimelineDocument,
): Promise<void> {
  const manifest = JSON.parse(
    await readFile(resolve(outputDirectory, 'manifest.json'), 'utf8'),
  ) as { frameCount: number };
  const frameLines = (await readFile(resolve(outputDirectory, 'frames.jsonl'), 'utf8'))
    .trim()
    .split('\n');
  const diskRecords = frameLines.map((line) => JSON.parse(line) as CapturedFrameRecord);
  const jpegFiles = (await readdir(resolve(outputDirectory, 'frames')))
    .filter((file) => file.endsWith('.jpg'))
    .sort();
  const timelineFromDisk = JSON.parse(
    await readFile(resolve(outputDirectory, 'timeline.json'), 'utf8'),
  ) as TimelineDocument;
  if (
    manifest.frameCount !== records.length ||
    diskRecords.length !== records.length ||
    jpegFiles.length !== records.length
  ) {
    throw new Error('Capture bundle frame counts differ');
  }
  for (let index = 0; index < records.length; index += 1) {
    const record = diskRecords[index];
    if (
      !record ||
      record.index !== index + 1 ||
      record.file !== `frames/${jpegFiles[index]}` ||
      record.pixelWidth !== 2880 ||
      record.pixelHeight !== 1800 ||
      !Number.isFinite(record.pageScaleFactor) ||
      !Number.isFinite(record.scrollOffsetX) ||
      !Number.isFinite(record.scrollOffsetY)
    ) {
      throw new Error(`Capture bundle frame ${index + 1} failed integrity validation`);
    }
  }
  if (timelineFromDisk.events.length !== 30 || timeline.events.length !== 30) {
    throw new Error('Capture bundle does not contain exactly 30 click events');
  }
}

function withoutMin(distribution: ReturnType<typeof summarizeDistribution>) {
  return {
    median: distribution.median,
    p95: distribution.p95,
    max: distribution.max,
  };
}

function printHumanSummary(
  summary: Day3GateSummary,
  staticRecords: ClickGateRecord[],
  hoverRecords: ClickGateRecord[],
  nearestFrameDistances: number[],
): void {
  const staticChanges = summarizeDistribution(
    staticRecords.map((record) => record.diagnostics.bboxChangeCssPx),
  );
  const hoverChanges = summarizeDistribution(
    hoverRecords.map((record) => record.diagnostics.bboxChangeCssPx),
  );
  const nearest = summarizeDistribution(nearestFrameDistances);
  process.stderr.write(
    [
      'Day 3 click gate',
      'target  clicks  bbox median  bbox max',
      `static  ${String(staticRecords.length).padStart(6)}  ${staticChanges.median.toFixed(3).padStart(11)}  ${staticChanges.max.toFixed(3).padStart(8)}`,
      `hover   ${String(hoverRecords.length).padStart(6)}  ${hoverChanges.median.toFixed(3).padStart(11)}  ${hoverChanges.max.toFixed(3).padStart(8)}`,
      `frames  ${summary.capture.frameCount}; local max gap ${summary.mouseDownFrameWindow.maxGapMs.toFixed(3)}ms`,
      `nearest-frame distance median/p95/max ${nearest.median.toFixed(3)}/${nearest.p95.toFixed(3)}/${nearest.max.toFixed(3)}ms`,
      `result  ${summary.passed ? 'PASS' : 'FAIL'}`,
      '',
    ].join('\n'),
  );
}

await mkdir(outputDirectory, { recursive: true });
const server = await startFixtureServer(0, fixtureDirectory);
const clickRecords: ClickGateRecord[] = [];
let captureOriginEpochMs = 0;
let finalApplicationClickCount = 0;
let finalStaticClickCount = 0;
let finalHoverClickCount = 0;

try {
  const result = await captureSession({
    url: `${server.url}/workspace`,
    outputDirectory,
    durationMs: 60_000,
    tailDurationMs: 750,
    sourceIdentifier: 'test/fixtures/web-app#day3-thirty-click-gate',
    scriptHash: await fixtureHash(),
    beforePageCreation: installPageInstrumentation,
    preparePage: async (page) => {
      await hideBrowserCursor(page);
      for (const testId of ['static-target', 'hover-target']) {
        const cursor = await page
          .getByTestId(testId)
          .evaluate((element) => getComputedStyle(element).cursor);
        if (cursor !== 'none') throw new Error(`${testId} browser cursor was not hidden`);
      }
      await page.mouse.move(720, 760);
    },
    runDuringCapture: async ({ page, captureOriginEpochMs: origin, startupCalibration }) => {
      captureOriginEpochMs = origin;
      let cursorPosition = { x: 720, y: 760 };
      for (let clickIndex = 0; clickIndex < 30; clickIndex += 1) {
        const isHover = clickIndex % 2 === 1;
        const recorded = await recordFixtureClick({
          id: `click-${String(clickIndex + 1).padStart(3, '0')}`,
          page,
          testId: isHover ? 'hover-target' : 'static-target',
          cursorPosition,
          viewport: { width: 1440, height: 900 },
          startupCalibration,
          captureOriginEpochMs: origin,
          requirePointerEnter: isHover,
          requireBboxChange: isHover,
        });
        cursorPosition = recorded.cursorPosition;
        clickRecords.push({ event: recorded.event, diagnostics: recorded.diagnostics });
      }
      finalApplicationClickCount = Number(
        (await page.locator('#click-count').textContent())?.replace('Clicks: ', ''),
      );
      finalStaticClickCount = Number(
        await page.getByTestId('static-target').getAttribute('data-application-clicks'),
      );
      finalHoverClickCount = Number(
        await page.getByTestId('hover-target').getAttribute('data-application-clicks'),
      );
    },
  });

  if (captureOriginEpochMs === 0) throw new Error('Capture origin was not established');
  const timeline: TimelineDocument = {
    schemaVersion: 1,
    events: clickRecords.map((record) => record.event),
  };
  validateTimelineDocument(timeline, result.manifest.captureDurationMs);
  await writeTimeline(outputDirectory, timeline, result.manifest.captureDurationMs);

  for (const record of clickRecords) {
    record.frameWindow = analyzeMouseDownFrameWindow(result.records, record.event.mouseDownMs);
    if (record.frameWindow.maxGapMs > 100) {
      throw new Error(`${record.event.id} has a local frame gap above 100ms`);
    }
    for (const event of record.diagnostics.observedEvents) {
      const timeMs = browserEpochToCaptureTimeMs(event.epochMs, captureOriginEpochMs);
      if (timeMs < 0 || timeMs > result.manifest.captureDurationMs) {
        throw new Error(`${record.event.id} browser event falls outside the capture`);
      }
    }
  }

  if (
    finalApplicationClickCount !== 30 ||
    finalStaticClickCount !== 15 ||
    finalHoverClickCount !== 15
  ) {
    throw new Error('Fixture application click totals do not match the gate');
  }
  if (
    result.manifest.viewport.width !== 1440 ||
    result.manifest.viewport.height !== 900 ||
    result.manifest.deviceScaleFactor !== 2 ||
    result.manifest.observedBrowserMetrics.innerWidth !== 1440 ||
    result.manifest.observedBrowserMetrics.innerHeight !== 900 ||
    result.manifest.observedBrowserMetrics.devicePixelRatio !== 2 ||
    !result.manifest.zoomHeadroomConfirmed ||
    result.manifest.duplicateTimestampCount !== 0 ||
    result.manifest.backwardTimestampCount !== 0
  ) {
    throw new Error('Capture manifest violates the Day-3 compatibility invariants');
  }

  await verifyBundle(result.records, timeline);
  const pointerDownCount = clickRecords.flatMap((record) =>
    record.diagnostics.observedEvents.filter((event) => event.type === 'pointerdown'),
  ).length;
  const clickEventCount = clickRecords.flatMap((record) =>
    record.diagnostics.observedEvents.filter((event) => event.type === 'click'),
  ).length;
  if (pointerDownCount !== 30 || clickEventCount !== 30) {
    throw new Error('Observed browser click-event totals do not match the gate');
  }

  const localGaps = clickRecords.map((record) => record.frameWindow?.maxGapMs ?? Number.NaN);
  const gapDistribution = summarizeDistribution(localGaps);
  const worstGap = Math.max(...localGaps);
  const worstIndex = localGaps.indexOf(worstGap);
  const worstRecord = clickRecords[worstIndex];
  if (!worstRecord?.frameWindow) throw new Error('Worst click frame diagnostics are unavailable');
  const pathDistribution = summarizeDistribution(
    clickRecords.map((record) => record.event.cursorPath.length),
  );
  const roundTripDistribution = summarizeDistribution(
    clickRecords.flatMap((record) => record.diagnostics.moveRoundTripMs),
  );
  const coordinateDistribution = summarizeDistribution(
    clickRecords.map((record) => record.diagnostics.pointerDownCoordinateErrorCssPx),
  );
  const bboxDistribution = summarizeDistribution(
    clickRecords.map((record) => record.diagnostics.bboxChangeCssPx),
  );
  const dimensions = result.manifest.observedFrameDimensions[0];
  if (!dimensions) throw new Error('Observed source dimensions are unavailable');

  const summary: Day3GateSummary = {
    passed: true,
    clickCount: clickRecords.length,
    staticClicks: finalStaticClickCount,
    hoverClicks: finalHoverClickCount,
    applicationClicksObserved: finalApplicationClickCount,
    pointerDownEventsObserved: pointerDownCount,
    clickEventsObserved: clickEventCount,
    pathPoints: pathDistribution,
    mouseMoveRoundTripMs: withoutMin(roundTripDistribution),
    pointerDownCoordinateErrorCssPx: withoutMin(coordinateDistribution),
    targetBboxChangeCssPx: withoutMin(bboxDistribution),
    mouseDownFrameWindow: {
      maxGapMs: worstGap,
      p95MaxGapMs: gapDistribution.p95,
      worstClickId: worstRecord.event.id,
      worstNearestFrameDistanceMs: worstRecord.frameWindow.nearestDistanceMs,
    },
    capture: {
      frameCount: result.manifest.frameCount,
      sourcePixelWidth: dimensions.pixelWidth,
      sourcePixelHeight: dimensions.pixelHeight,
      received: result.manifest.queue.received,
      acknowledged: result.manifest.queue.acknowledged,
      written: result.manifest.queue.written,
      queueHighWaterMark: result.manifest.queue.highWaterMark,
      queueOverflows: result.manifest.queue.overflowCount,
    },
  };
  const staticRecords = clickRecords.filter(
    (record) => record.event.target.value.testId === 'static-target',
  );
  const hoverRecords = clickRecords.filter(
    (record) => record.event.target.value.testId === 'hover-target',
  );
  printHumanSummary(
    summary,
    staticRecords,
    hoverRecords,
    clickRecords.map((record) => record.frameWindow?.nearestDistanceMs ?? Number.NaN),
  );
  process.stdout.write(`${JSON.stringify(summary)}\n`);
} finally {
  await server.close();
}
