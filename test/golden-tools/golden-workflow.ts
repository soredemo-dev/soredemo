import { copyFile, cp, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { relative, resolve } from 'node:path';
import {
  CANONICAL_INPUT_ROOT,
  CHECKED_GOLDEN_ROOT,
  GOLDEN_CANDIDATE_ROOT,
  generateExactCandidate,
} from './exact-authority.js';
import { readCanonicalInputManifest, verifyCanonicalInputHashes } from './input-hashes.js';
import { compareRgba, pngToRgba, rgbaToPng } from './pixel-diff.js';
import {
  inspectExactProfile,
  officialExactProfile,
  requireOfficialExactProfile,
  sha256,
  stableJson,
} from './profile.js';
import { type ExactGoldenManifest, GoldenError } from './types.js';

export const GOLDEN_DIFF_ROOT = resolve('.tmp/golden-diff');

export interface VerificationResult {
  passed: boolean;
  authoritative: boolean;
  exactCompared: boolean;
  profileStatus: 'MATCHED' | 'GOLDEN_PROFILE_MISMATCH';
  frameCount: number;
  structuralAssertions: Record<string, boolean>;
  diagnosticPath?: string;
}

export async function verifyCheckedGoldens(): Promise<VerificationResult> {
  const runtime = await inspectExactProfile();
  const candidate = await generateExactCandidate(resolve('.tmp/golden-verify'));
  if (!officialExactProfile(runtime)) {
    return {
      passed: Object.values(candidate.manifest.structuralAssertions).every(Boolean),
      authoritative: false,
      exactCompared: false,
      profileStatus: 'GOLDEN_PROFILE_MISMATCH',
      frameCount: candidate.manifest.frames.length,
      structuralAssertions: candidate.manifest.structuralAssertions,
    };
  }
  return verifyManifests(CHECKED_GOLDEN_ROOT, resolve('.tmp/golden-verify'));
}

export async function verifyCandidate(): Promise<VerificationResult> {
  requireOfficialExactProfile(await inspectExactProfile());
  return verifyManifests(CHECKED_GOLDEN_ROOT, GOLDEN_CANDIDATE_ROOT);
}

export async function promoteCandidate(confirm: boolean): Promise<void> {
  if (!confirm) throw new Error('Golden promotion requires --confirm');
  requireOfficialExactProfile(await inspectExactProfile());
  const manifest = await readGoldenManifest(resolve(GOLDEN_CANDIDATE_ROOT, 'manifest.json'));
  await validateGoldenFiles(GOLDEN_CANDIDATE_ROOT, manifest);
  const staging = resolve('.tmp/golden-promotion');
  await rm(staging, { recursive: true, force: true });
  await mkdir(staging, { recursive: true });
  await copyFile(
    resolve(GOLDEN_CANDIDATE_ROOT, 'manifest.json'),
    resolve(staging, 'manifest.json'),
  );
  await cp(resolve(GOLDEN_CANDIDATE_ROOT, 'frames'), resolve(staging, 'frames'), {
    recursive: true,
  });
  await rm(CHECKED_GOLDEN_ROOT, { recursive: true, force: true });
  await mkdir(resolve(CHECKED_GOLDEN_ROOT, '..'), { recursive: true });
  await cp(staging, CHECKED_GOLDEN_ROOT, { recursive: true });
}

export async function verifyManifests(
  expectedRoot: string,
  actualRoot: string,
): Promise<VerificationResult> {
  const expected = await readGoldenManifest(resolve(expectedRoot, 'manifest.json'));
  const actual = await readGoldenManifest(resolve(actualRoot, 'manifest.json'));
  await validateGoldenFiles(expectedRoot, expected);
  await validateGoldenFiles(actualRoot, actual);
  const canonicalManifest = await readCanonicalInputManifest(CANONICAL_INPUT_ROOT);
  await verifyCanonicalInputHashes(CANONICAL_INPUT_ROOT, canonicalManifest);
  const changedInputs = Object.keys(expected.canonicalInputs).filter(
    (file) => expected.canonicalInputs[file] !== actual.canonicalInputs[file],
  );
  if (changedInputs.length > 0) {
    throw new GoldenError(
      'GOLDEN_INPUT_CHANGED',
      'Canonical inputs differ from the golden authority',
      {
        changedInputs,
      },
    );
  }
  const expectedByPurpose = new Map(expected.frames.map((frame) => [frame.purpose, frame]));
  const mismatches: Array<{ purpose: string; reasons: string[] }> = [];
  for (const actualFrame of actual.frames) {
    const expectedFrame = expectedByPurpose.get(actualFrame.purpose);
    if (!expectedFrame) {
      throw new GoldenError(
        'GOLDEN_FRAME_MISSING',
        `Unexpected semantic frame ${actualFrame.purpose}`,
      );
    }
    const reasons: string[] = [];
    if (expectedFrame.rgbaSha256 !== actualFrame.rgbaSha256) reasons.push('rgba');
    if (expectedFrame.pngSha256 !== actualFrame.pngSha256) reasons.push('png');
    if (
      stableJson(metadataForComparison(expectedFrame)) !==
      stableJson(metadataForComparison(actualFrame))
    ) {
      reasons.push('metadata');
    }
    if (reasons.length > 0) mismatches.push({ purpose: actualFrame.purpose, reasons });
  }
  if (actual.frames.length !== expected.frames.length) {
    throw new GoldenError('GOLDEN_FRAME_MISSING', 'Golden semantic frame counts differ');
  }
  if (mismatches.length > 0) {
    await writeMismatchDiagnostics(expectedRoot, actualRoot, expected, actual, mismatches);
    const metadataOnly = mismatches.every(({ reasons }) =>
      reasons.every((reason) => reason === 'metadata'),
    );
    throw new GoldenError(
      metadataOnly ? 'GOLDEN_STRUCTURE_MISMATCH' : 'GOLDEN_RGBA_MISMATCH',
      'Exact synthetic compositor output differs from the checked golden',
      { mismatches, diagnosticPath: GOLDEN_DIFF_ROOT },
    );
  }
  const structuralAssertions = actual.structuralAssertions;
  if (Object.values(structuralAssertions).some((value) => !value)) {
    throw new GoldenError('GOLDEN_STRUCTURE_MISMATCH', 'Synthetic structural assertions failed', {
      structuralAssertions,
    });
  }
  return {
    passed: true,
    authoritative: true,
    exactCompared: true,
    profileStatus: 'MATCHED',
    frameCount: actual.frames.length,
    structuralAssertions,
  };
}

export async function readGoldenManifest(file: string): Promise<ExactGoldenManifest> {
  let value: ExactGoldenManifest;
  try {
    value = JSON.parse(await readFile(file, 'utf8')) as ExactGoldenManifest;
  } catch (error) {
    throw new GoldenError('GOLDEN_MANIFEST_INVALID', `Unable to read ${file}`, {
      cause: error instanceof Error ? error.message : String(error),
    });
  }
  if (
    value.schemaVersion !== 1 ||
    value.authority !== 'exact-synthetic-compositor' ||
    !Array.isArray(value.frames) ||
    !value.profile ||
    !value.canonicalInputs
  ) {
    throw new GoldenError('GOLDEN_MANIFEST_INVALID', 'Golden manifest structure is invalid');
  }
  const purposes = new Set<string>();
  for (const frame of value.frames) {
    if (!frame.purpose || purposes.has(frame.purpose)) {
      throw new GoldenError('GOLDEN_MANIFEST_INVALID', 'Golden frame purposes must be unique');
    }
    purposes.add(frame.purpose);
    safeGoldenFile(frame.file);
    if (!/^[a-f\d]{64}$/u.test(frame.pngSha256) || !/^[a-f\d]{64}$/u.test(frame.rgbaSha256)) {
      throw new GoldenError('GOLDEN_MANIFEST_INVALID', `${frame.purpose} has an invalid hash`);
    }
  }
  return value;
}

async function validateGoldenFiles(root: string, manifest: ExactGoldenManifest): Promise<void> {
  for (const frame of manifest.frames) {
    const file = resolve(root, safeGoldenFile(frame.file));
    let bytes: Buffer;
    try {
      const info = await stat(file);
      if (!info.isFile()) throw new Error('not a regular file');
      bytes = await readFile(file);
    } catch (error) {
      throw new GoldenError('GOLDEN_FRAME_MISSING', `Golden frame ${frame.file} is missing`, {
        cause: error instanceof Error ? error.message : String(error),
      });
    }
    if (sha256(bytes) !== frame.pngSha256) {
      throw new GoldenError('GOLDEN_MANIFEST_INVALID', `${frame.file} PNG hash is invalid`);
    }
  }
}

function safeGoldenFile(file: string): string {
  if (file.startsWith('/') || file.includes('\\') || relative('.', file).startsWith('..')) {
    throw new GoldenError('GOLDEN_MANIFEST_INVALID', `Unsafe golden frame path ${file}`);
  }
  return file;
}

function metadataForComparison(frame: ExactGoldenManifest['frames'][number]): unknown {
  const { pngSha256: _png, rgbaSha256: _rgba, ...metadata } = frame;
  return metadata;
}

async function writeMismatchDiagnostics(
  expectedRoot: string,
  actualRoot: string,
  expected: ExactGoldenManifest,
  actual: ExactGoldenManifest,
  mismatches: readonly { purpose: string; reasons: string[] }[],
): Promise<void> {
  await rm(GOLDEN_DIFF_ROOT, { recursive: true, force: true });
  for (const directory of ['expected', 'actual', 'diff', 'heatmap']) {
    await mkdir(resolve(GOLDEN_DIFF_ROOT, directory), { recursive: true });
  }
  const expectedByPurpose = new Map(expected.frames.map((frame) => [frame.purpose, frame]));
  const actualByPurpose = new Map(actual.frames.map((frame) => [frame.purpose, frame]));
  const diagnostics = [];
  for (const mismatch of mismatches) {
    const expectedFrame = expectedByPurpose.get(mismatch.purpose);
    const actualFrame = actualByPurpose.get(mismatch.purpose);
    if (!expectedFrame || !actualFrame) continue;
    const expectedPng = await readFile(resolve(expectedRoot, safeGoldenFile(expectedFrame.file)));
    const actualPng = await readFile(resolve(actualRoot, safeGoldenFile(actualFrame.file)));
    const expectedRgba = await pngToRgba(expectedPng);
    const actualRgba = await pngToRgba(actualPng);
    if (expectedRgba.width !== actualRgba.width || expectedRgba.height !== actualRgba.height) {
      throw new GoldenError('GOLDEN_RGBA_MISMATCH', `${mismatch.purpose} dimensions differ`);
    }
    const comparison = compareRgba(
      expectedRgba.data,
      actualRgba.data,
      expectedRgba.width,
      expectedRgba.height,
    );
    const name = `${mismatch.purpose}.png`;
    await copyFile(
      resolve(expectedRoot, expectedFrame.file),
      resolve(GOLDEN_DIFF_ROOT, 'expected', name),
    );
    await copyFile(
      resolve(actualRoot, actualFrame.file),
      resolve(GOLDEN_DIFF_ROOT, 'actual', name),
    );
    await writeFile(
      resolve(GOLDEN_DIFF_ROOT, 'diff', name),
      rgbaToPng(comparison.difference, expectedRgba.width, expectedRgba.height),
    );
    await writeFile(
      resolve(GOLDEN_DIFF_ROOT, 'heatmap', name),
      rgbaToPng(comparison.heatmap, expectedRgba.width, expectedRgba.height),
    );
    diagnostics.push({
      purpose: mismatch.purpose,
      reasons: mismatch.reasons,
      ...comparison.statistics,
    });
  }
  await writeFile(
    resolve(GOLDEN_DIFF_ROOT, 'manifest.json'),
    stableJson({ schemaVersion: 1, mismatches: diagnostics }),
  );
}
