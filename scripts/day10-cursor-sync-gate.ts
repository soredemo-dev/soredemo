import { readFile, stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import type {
  CursorActionLandingMeasurement,
  CursorBearingTimelineEvent,
} from '../src/compositor/cursor-action-landing.js';
import type { CursorProofFrameRecord } from '../src/render/cursor-action-audit.js';
import type { DecodedCursorProofRecord } from '../src/render/mp4-cursor-proof.js';
import type { TimelineDocument } from '../src/timeline/types.js';

const workspaceArgument = process.argv.slice(2).find((argument) => argument !== '--');
const workspace = resolve(workspaceArgument ?? '');
if (!workspaceArgument) throw new Error('Usage: pnpm gate:cursor-sync -- <run-workspace>');

const [timeline, landingDocument, proofDocument, mp4Proofs, compositionManifest, captureManifest] =
  await Promise.all([
    json<TimelineDocument>('capture/timeline.json'),
    json<{ measurements: CursorActionLandingMeasurement[] }>(
      'composition/cursor-action-landings.json',
    ),
    json<{ proofs: CursorProofFrameRecord[] }>('composition/cursor-proof-frames.json'),
    json<DecodedCursorProofRecord[]>('composition/mp4-cursor-proofs.json'),
    json<{ frameCount: number }>('composition/manifest.json'),
    json<{
      viewport: { width: number; height: number };
      deviceScaleFactor: number;
      captureSurface: { method: string; browserMode: string };
      observedFrameDimensions: Array<{ pixelWidth: number; pixelHeight: number }>;
    }>('capture/manifest.json'),
  ]);

const cursorEvents = timeline.events.filter(
  (event): event is CursorBearingTimelineEvent =>
    event.kind === 'moveTo' || event.kind === 'click' || event.kind === 'type',
);
const eventCounts = countKinds(cursorEvents);
const measurementCounts = countKinds(landingDocument.measurements);
assertCounts(eventCounts, 'timeline');
assertCounts(measurementCounts, 'landing measurements');
if (captureManifest.viewport.width !== 1440 || captureManifest.viewport.height !== 900) {
  throw new Error('Fixture capture viewport is not 1440x900');
}
if (
  captureManifest.deviceScaleFactor !== 2 ||
  captureManifest.captureSurface.method !== 'chromium-force-device-scale-factor' ||
  captureManifest.captureSurface.browserMode !== 'headless' ||
  captureManifest.observedFrameDimensions.some(
    (dimensions) => dimensions.pixelWidth !== 2880 || dimensions.pixelHeight !== 1800,
  )
) {
  throw new Error('Fixture capture does not prove the genuine 2x surface contract');
}

const hoverEvent = cursorEvents.find((event) => event.kind === 'moveTo');
if (
  hoverEvent?.actionIndex !== 1 ||
  hoverEvent.target.strategy !== 'testId' ||
  hoverEvent.target.value.testId !== 'hover-target'
) {
  throw new Error('Growing hover target is not represented by moveTo action index 1');
}

for (const measurement of landingDocument.measurements) {
  if (
    measurement.errorDistanceOutputPx > 2 ||
    !measurement.hotspotInsideProjectedTarget ||
    !Number.isFinite(measurement.targetVisibleFraction) ||
    Math.abs(measurement.targetVisibleFraction - 1) > 1e-7 ||
    measurement.cursorPixelsChanged < 1
  ) {
    throw new Error(`${measurement.eventId} failed its composed cursor landing gate`);
  }
  if (
    measurement.kind === 'moveTo' &&
    (!measurement.pointerEnterObserved ||
      !measurement.heldAtActionCompletion ||
      !measurement.heldUntilNextCursorAction)
  ) {
    throw new Error(`${measurement.eventId} did not preserve genuine hover and hold behavior`);
  }
  if (measurement.kind === 'type' && !measurement.focusVerified) {
    throw new Error(`${measurement.eventId} did not verify real input focus`);
  }
  const expectedRole = measurement.kind === 'click' ? 'mouse-down' : 'path-completion';
  const proof = proofDocument.proofs.find(
    (candidate) => candidate.eventId === measurement.eventId && candidate.role === expectedRole,
  );
  if (!proof) throw new Error(`${measurement.eventId} has no RGBA landing proof`);
  if (
    proof.targetPixelEvidence.rgbStandardDeviation < 10 ||
    proof.targetPixelEvidence.nonUniformFraction < 0.05
  ) {
    throw new Error(
      `${measurement.eventId} projected target bbox does not contain the visible fixture target`,
    );
  }
  const decoded = mp4Proofs.find(
    (candidate) => candidate.eventId === measurement.eventId && candidate.role === expectedRole,
  );
  if (!decoded?.correspondsToOutputIndex) {
    throw new Error(`${measurement.eventId} decoded MP4 proof does not match its RGBA frame`);
  }
  await Promise.all([
    stat(resolve(workspace, 'composition', proof.file)),
    stat(resolve(workspace, 'composition', decoded.decodedFrameFile)),
    stat(resolve(workspace, 'composition', decoded.decodedCropFile)),
  ]);
}

const frameHashes = (await readFile(resolve(workspace, 'composition/frame-hashes.jsonl'), 'utf8'))
  .trim()
  .split('\n')
  .map((line) => JSON.parse(line) as { outputIndex: number; rgbaSha256: string });
if (
  frameHashes.length !== compositionManifest.frameCount ||
  frameHashes.some(
    (frame, index) => frame.outputIndex !== index || !/^[0-9a-f]{64}$/.test(frame.rgbaSha256),
  )
) {
  throw new Error('Composed frame hashes do not match consecutive output indexes');
}
if (
  mp4Proofs.length !== proofDocument.proofs.length ||
  mp4Proofs.some((proof) => !proof.correspondsToOutputIndex)
) {
  throw new Error('Encoded MP4 proof frames do not preserve compositor output ordering');
}

const finalPoint = hoverEvent.cursorPath.at(-1);
const nextCursorEvent = cursorEvents[cursorEvents.indexOf(hoverEvent) + 1];
const hoverMeasurement = landingDocument.measurements.find(
  (measurement) => measurement.eventId === hoverEvent.id,
);
process.stdout.write(
  `${JSON.stringify({
    passed: true,
    workspace,
    affectedAction: {
      actionIndex: hoverEvent.actionIndex,
      kind: hoverEvent.kind,
      eventId: hoverEvent.id,
      target: hoverEvent.target,
      startMs: hoverEvent.startMs,
      endMs: hoverEvent.endMs,
      firstPoint: hoverEvent.cursorPath[0],
      finalPoint,
      destinationPoint: hoverEvent.destinationPoint,
      nextCursorAction: nextCursorEvent
        ? {
            eventId: nextCursorEvent.id,
            kind: nextCursorEvent.kind,
            startMs: nextCursorEvent.startMs,
          }
        : null,
    },
    eventCounts,
    measurementCounts,
    hoverLanding: hoverMeasurement,
    rgbaProofFrames: proofDocument.proofs.length,
    decodedMp4ProofFrames: mp4Proofs.length,
    encodedFrameOrderMatches: true,
  })}\n`,
);

async function json<T>(file: string): Promise<T> {
  return JSON.parse(await readFile(resolve(workspace, file), 'utf8')) as T;
}

function countKinds(values: readonly { kind: string }[]) {
  return {
    moveTo: values.filter((value) => value.kind === 'moveTo').length,
    click: values.filter((value) => value.kind === 'click').length,
    type: values.filter((value) => value.kind === 'type').length,
  };
}

function assertCounts(counts: ReturnType<typeof countKinds>, label: string): void {
  if (counts.moveTo !== 1 || counts.click !== 2 || counts.type !== 1) {
    throw new Error(`${label} must contain one moveTo, two clicks, and one type focus`);
  }
}
