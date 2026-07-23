import { createHash, randomBytes } from 'node:crypto';
import { mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { basename, dirname, resolve } from 'node:path';
import { packageMetadata } from '../cli/package-metadata.js';
import { type ProofManifest, ProofManifestSchema } from './schema.js';

function sha256(value: Buffer | string): string {
  return createHash('sha256').update(value).digest('hex');
}

async function json(path: string): Promise<Record<string, unknown>> {
  return JSON.parse(await readFile(path, 'utf8')) as Record<string, unknown>;
}

async function fileHash(path: string): Promise<string> {
  return sha256(await readFile(path));
}

export async function writeProofBundle(options: {
  directory: string;
  workspace: string;
  planFile: string;
  configFile?: string;
  outputPath: string;
}): Promise<{ path: string; level: 'encoded-verified'; manifestSha256: string }> {
  const target = resolve(options.directory);
  try {
    await stat(target);
    throw new Error(`Proof output already exists: ${target}`);
  } catch (error) {
    if (error instanceof Error && !('code' in error && error.code === 'ENOENT')) throw error;
  }
  const temporary = resolve(
    dirname(target),
    `.${basename(target)}.${randomBytes(8).toString('hex')}.partial`,
  );
  await mkdir(temporary, { recursive: true });
  try {
    const [timeline, capture, cursor, media] = await Promise.all([
      json(resolve(options.workspace, 'capture/timeline.json')),
      json(resolve(options.workspace, 'capture/manifest.json')),
      json(resolve(options.workspace, 'composition/manifest.json')),
      json(resolve(options.workspace, 'encode/manifest.json')),
    ]);
    const actions = {
      schemaVersion: 1,
      events: Array.isArray(timeline.events)
        ? timeline.events.map((entry) => {
            const event = entry as Record<string, unknown>;
            return {
              id: event.id,
              actionIndex: event.actionIndex,
              kind: event.kind,
              startMs: event.startMs,
              endMs: event.endMs,
              ...(event.target ? { target: event.target } : {}),
              ...(event.textLength === undefined ? {} : { textLength: event.textLength }),
            };
          })
        : [],
      allTargetsUniquelyResolved: true,
    };
    const captureSummary = {
      schemaVersion: 1,
      frameCount: capture.frameCount,
      dimensions: capture.expectedFrameDimensions,
      paintedScale: capture.pixelScaleProof,
      timestampIntegrity: capture.timestampIntegrity,
      queue: capture.queue,
    };
    const cursorSummary = {
      schemaVersion: 1,
      cursorActionLandings: cursor.cursorActionLandings,
      decodedCursorProofCount: cursor.decodedCursorProofCount,
    };
    const encodedOutput = media.output as Record<string, unknown> | undefined;
    const validatedVideo = media.video as Record<string, unknown> | undefined;
    const mediaSummary = {
      schemaVersion: 1,
      output: {
        byteLength: encodedOutput?.byteLength,
        sha256: encodedOutput?.sha256,
        frameCount: encodedOutput?.frameCount,
        ffmpegExitCode: encodedOutput?.ffmpegExitCode,
        ffmpegSignal: encodedOutput?.ffmpegSignal,
        backpressure: encodedOutput?.backpressure,
      },
      video: {
        codecName: validatedVideo?.codecName,
        profile: validatedVideo?.profile,
        level: validatedVideo?.level,
        pixelFormat: validatedVideo?.pixelFormat,
        width: validatedVideo?.width,
        height: validatedVideo?.height,
        averageFrameRate: validatedVideo?.averageFrameRate,
        realFrameRate: validatedVideo?.realFrameRate,
        frameCount: validatedVideo?.frameCount,
        durationSeconds: validatedVideo?.durationSeconds,
        audioStreams: validatedVideo?.audioStreams,
        fastStart: validatedVideo?.fastStart,
        colorPrimaries: validatedVideo?.colorPrimaries,
        colorTransfer: validatedVideo?.colorTransfer,
        colorSpace: validatedVideo?.colorSpace,
        colorRange: validatedVideo?.colorRange,
      },
      maximumPendingFrames: (encodedOutput?.backpressure as Record<string, unknown> | undefined)
        ?.maxPendingFrames,
    };
    const documents: Record<string, unknown> = {
      'actions.json': actions,
      'capture.json': captureSummary,
      'cursor.json': cursorSummary,
      'media.json': mediaSummary,
    };
    for (const [name, document] of Object.entries(documents)) {
      await writeFile(resolve(temporary, name), `${JSON.stringify(document, null, 2)}\n`);
    }
    const configSha256 = options.configFile
      ? await fileHash(options.configFile)
      : sha256('soredemo-built-in-default-config-v1');
    const fileHashes = Object.fromEntries(
      await Promise.all(
        Object.keys(documents).map(async (name) => [
          name,
          await fileHash(resolve(temporary, name)),
        ]),
      ),
    );
    const manifest: ProofManifest = {
      schemaVersion: 1,
      producer: { name: 'soredemo', version: packageMetadata().version },
      proofLevel: 'encoded-verified',
      planSha256: await fileHash(options.planFile),
      configSha256,
      outputMp4Sha256: await fileHash(options.outputPath),
      files: fileHashes,
      completed: true,
    };
    ProofManifestSchema.parse(manifest);
    const manifestSource = `${JSON.stringify(manifest, null, 2)}\n`;
    await writeFile(resolve(temporary, 'manifest.json'), manifestSource);
    const sums = [...Object.entries(fileHashes), ['manifest.json', sha256(manifestSource)]]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([name, hash]) => `${hash}  ${name}`)
      .join('\n');
    await writeFile(resolve(temporary, 'SHA256SUMS'), `${sums}\n`);
    await rename(temporary, target);
    return { path: target, level: 'encoded-verified', manifestSha256: sha256(manifestSource) };
  } catch (error) {
    await rm(temporary, { recursive: true, force: true });
    throw error;
  }
}
