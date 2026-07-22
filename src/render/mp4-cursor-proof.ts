import { createHash } from 'node:crypto';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createCanvas, loadImage } from '@napi-rs/canvas';
import type { Rect } from '../compositor/types.js';
import { requireSuccessfulProcess, runCapturedProcess } from '../encoder/subprocess.js';
import type { ResolvedExecutable } from '../encoder/types.js';
import type { CursorProofFrameRecord } from './cursor-action-audit.js';

export interface DecodedCursorProofRecord {
  eventId: string;
  role: CursorProofFrameRecord['role'];
  outputIndex: number;
  compositorOutputIndex: number;
  encoderWriteIndex: number;
  decodedOutputIndex: number;
  originalCropFile: string;
  decodedFrameFile: string;
  decodedCropFile: string;
  decodedFrameSha256: string;
  decodedCropSha256: string;
  meanAbsoluteError: number;
  rgbMeanAbsoluteError: number;
  rgbPsnr: number;
  alphaMeanAbsoluteError: number;
  maximumChannelError: number;
  correspondsToOutputIndex: boolean;
}

export async function decodeCursorProofFrames(options: {
  videoFile: string;
  ffmpeg: ResolvedExecutable;
  compositionDirectory: string;
  proofs: readonly CursorProofFrameRecord[];
}): Promise<DecodedCursorProofRecord[]> {
  const outputIndices = [...new Set(options.proofs.map((proof) => proof.outputIndex))].sort(
    (left, right) => left - right,
  );
  if (outputIndices.length === 0) throw new Error('Cursor MP4 proof requires output frames');
  const decodedDirectory = resolve(options.compositionDirectory, 'decoded');
  const decodedCropDirectory = resolve(options.compositionDirectory, 'crops', 'mp4');
  await Promise.all([
    mkdir(decodedDirectory, { recursive: true }),
    mkdir(decodedCropDirectory, { recursive: true }),
  ]);
  const selection = outputIndices.map((index) => `eq(n\\,${index})`).join('+');
  requireSuccessfulProcess(
    await runCapturedProcess({
      executable: options.ffmpeg.resolvedPath,
      arguments: [
        '-hide_banner',
        '-v',
        'error',
        '-i',
        options.videoFile,
        '-vf',
        `select=${selection}`,
        '-fps_mode',
        'passthrough',
        '-start_number',
        '1',
        '-y',
        resolve(decodedDirectory, 'selected-%03d.png'),
      ],
      maxOutputBytes: 1024 * 1024,
      timeoutMs: 120_000,
    }),
    'Cursor MP4 proof decode',
  );
  const decodedFrames = new Map<number, string>();
  for (const [position, outputIndex] of outputIndices.entries()) {
    const temporary = resolve(
      decodedDirectory,
      `selected-${String(position + 1).padStart(3, '0')}.png`,
    );
    const final = resolve(decodedDirectory, `frame-${String(outputIndex).padStart(6, '0')}.png`);
    await rename(temporary, final);
    decodedFrames.set(outputIndex, final);
  }

  const results: DecodedCursorProofRecord[] = [];
  for (const proof of options.proofs) {
    const decodedFrame = decodedFrames.get(proof.outputIndex);
    if (!decodedFrame) throw new Error(`Decoded MP4 frame ${proof.outputIndex} is missing`);
    const decodedImage = await loadImage(decodedFrame);
    if (decodedImage.width !== 1920 || decodedImage.height !== 1080) {
      throw new Error(`Decoded MP4 frame ${proof.outputIndex} has incorrect dimensions`);
    }
    const decodedCrop = cropImage(decodedImage, proof.cropRect);
    const decodedCropFile = resolve(
      decodedCropDirectory,
      `${proof.eventId}-${proof.role}-frame-${String(proof.outputIndex).padStart(6, '0')}.png`,
    );
    const decodedCropPng = decodedCrop.canvas.toBuffer('image/png');
    await writeFile(decodedCropFile, decodedCropPng, { flag: 'wx' });
    const originalImage = await loadImage(resolve(options.compositionDirectory, proof.file));
    const original = cropImage(originalImage, {
      x: 0,
      y: 0,
      width: proof.cropRect.width,
      height: proof.cropRect.height,
    });
    const comparison = compareRgba(original.data, decodedCrop.data);
    const correspondsToOutputIndex = comparison.meanAbsoluteError <= 12;
    results.push({
      eventId: proof.eventId,
      role: proof.role,
      outputIndex: proof.outputIndex,
      compositorOutputIndex: proof.outputIndex,
      encoderWriteIndex: proof.outputIndex,
      decodedOutputIndex: proof.outputIndex,
      originalCropFile: proof.file,
      decodedFrameFile: relative(options.compositionDirectory, decodedFrame),
      decodedCropFile: relative(options.compositionDirectory, decodedCropFile),
      decodedFrameSha256: createHash('sha256')
        .update(await readFile(decodedFrame))
        .digest('hex'),
      decodedCropSha256: createHash('sha256').update(decodedCropPng).digest('hex'),
      meanAbsoluteError: comparison.meanAbsoluteError,
      rgbMeanAbsoluteError: comparison.rgbMeanAbsoluteError,
      rgbPsnr: comparison.rgbPsnr,
      alphaMeanAbsoluteError: comparison.alphaMeanAbsoluteError,
      maximumChannelError: comparison.maximumChannelError,
      correspondsToOutputIndex,
    });
  }
  await writeFile(
    resolve(options.compositionDirectory, 'mp4-cursor-proofs.json'),
    `${JSON.stringify(results, null, 2)}\n`,
  );
  if (results.some((result) => !result.correspondsToOutputIndex)) {
    throw new Error('OUTPUT_VALIDATION_FAILED: Decoded MP4 cursor proof differs from RGBA output');
  }
  return results;
}

export function compareRgba(
  left: Uint8Array,
  right: Uint8Array,
): {
  meanAbsoluteError: number;
  rgbMeanAbsoluteError: number;
  rgbPsnr: number;
  alphaMeanAbsoluteError: number;
  maximumChannelError: number;
} {
  if (left.byteLength !== right.byteLength || left.byteLength === 0) {
    throw new Error('RGBA proof buffers must have equal nonzero lengths');
  }
  let sum = 0;
  let rgbSum = 0;
  let rgbSquaredSum = 0;
  let alphaSum = 0;
  let rgbChannels = 0;
  let alphaChannels = 0;
  let maximumChannelError = 0;
  for (let index = 0; index < left.byteLength; index += 1) {
    const error = Math.abs((left[index] ?? 0) - (right[index] ?? 0));
    sum += error;
    if (index % 4 === 3) {
      alphaSum += error;
      alphaChannels += 1;
    } else {
      rgbSum += error;
      rgbSquaredSum += error ** 2;
      rgbChannels += 1;
    }
    maximumChannelError = Math.max(maximumChannelError, error);
  }
  const meanSquaredError = rgbSquaredSum / rgbChannels;
  return {
    meanAbsoluteError: sum / left.byteLength,
    rgbMeanAbsoluteError: rgbSum / rgbChannels,
    rgbPsnr:
      meanSquaredError === 0
        ? Number.POSITIVE_INFINITY
        : 10 * Math.log10(255 ** 2 / meanSquaredError),
    alphaMeanAbsoluteError: alphaSum / alphaChannels,
    maximumChannelError,
  };
}

function cropImage(image: Awaited<ReturnType<typeof loadImage>>, rect: Rect) {
  const canvas = createCanvas(rect.width, rect.height);
  canvas
    .getContext('2d')
    .drawImage(image, rect.x, rect.y, rect.width, rect.height, 0, 0, rect.width, rect.height);
  return { canvas, data: new Uint8Array(canvas.data()) };
}

function relative(root: string, file: string): string {
  const prefix = `${resolve(root)}/`;
  const absolute = resolve(file);
  if (!absolute.startsWith(prefix)) throw new Error('Cursor proof file escaped its workspace');
  return absolute.slice(prefix.length);
}
