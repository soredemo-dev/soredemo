import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { verifyProofBundle } from '../../src/proof/verify-proof.js';
import { writeProofBundle } from '../../src/proof/write-proof.js';

describe('public proof bundle', () => {
  it('serializes existing production evidence atomically without typed values or absolute paths', async () => {
    const root = await mkdtemp(resolve(tmpdir(), 'soredemo-proof-'));
    const workspace = resolve(root, 'workspace');
    for (const directory of ['capture', 'composition', 'encode'])
      await mkdir(resolve(workspace, directory), { recursive: true });
    const plan = resolve(root, 'plan.yaml');
    const output = resolve(root, 'video.mp4');
    await writeFile(plan, 'version: 1\n');
    await writeFile(output, 'video bytes');
    await writeFile(
      resolve(workspace, 'capture/timeline.json'),
      JSON.stringify({
        schemaVersion: 1,
        events: [
          { id: 'type-001', actionIndex: 0, kind: 'type', startMs: 0, endMs: 100, textLength: 12 },
        ],
      }),
    );
    await writeFile(
      resolve(workspace, 'capture/manifest.json'),
      JSON.stringify({
        frameCount: 10,
        expectedFrameDimensions: { pixelWidth: 2880, pixelHeight: 1800 },
        pixelScaleProof: { passed: true },
        timestampIntegrity: { backward: 0 },
        queue: { overflow: 0 },
      }),
    );
    await writeFile(
      resolve(workspace, 'composition/manifest.json'),
      JSON.stringify({
        cursorActionLandings: { total: 1, failures: 0 },
        decodedCursorProofCount: 1,
      }),
    );
    await writeFile(
      resolve(workspace, 'encode/manifest.json'),
      JSON.stringify({
        output: {
          outputPath: '/private/path/video.mp4',
          byteLength: 11,
          sha256: 'a'.repeat(64),
          frameCount: 10,
          backpressure: { maxPendingFrames: 1 },
        },
        video: {
          codecName: 'h264',
          pixelFormat: 'yuv420p',
          width: 1920,
          height: 1080,
          frameCount: 10,
          durationSeconds: 1 / 3,
          audioStreams: 0,
          fastStart: true,
        },
        ffmpeg: { executable: '/opt/private/ffmpeg' },
      }),
    );
    const proof = await writeProofBundle({
      directory: resolve(root, 'video.proof'),
      workspace,
      planFile: plan,
      outputPath: output,
    });
    await expect(verifyProofBundle(proof.path)).resolves.toMatchObject({
      valid: true,
      proofLevel: 'encoded-verified',
    });
    const all = await Promise.all(
      ['manifest.json', 'actions.json', 'capture.json', 'cursor.json', 'media.json'].map((file) =>
        readFile(resolve(proof.path, file), 'utf8'),
      ),
    );
    expect(all.join('\n')).not.toContain('/private/');
    expect(all.join('\n')).not.toContain('Private value');
    expect(all.join('\n')).toContain('"textLength": 12');
  });
});
