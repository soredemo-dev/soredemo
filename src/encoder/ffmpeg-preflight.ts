import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { requireSuccessfulProcess, runCapturedProcess } from './subprocess.js';
import type { FfmpegCapabilities, ResolvedExecutable } from './types.js';

async function sha256File(file: string): Promise<string> {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk as Buffer);
  return hash.digest('hex');
}

async function diagnostic(executable: string, args: string[], label: string): Promise<string> {
  const result = requireSuccessfulProcess(
    await runCapturedProcess({ executable, arguments: ['-hide_banner', ...args] }),
    label,
  );
  return Buffer.concat([result.stdout, result.stderr]).toString('utf8').trim();
}

function firstLine(value: string, prefix: string): string {
  const line = value.split(/\r?\n/).find((item) => item.startsWith(prefix));
  if (!line) throw new Error(`Missing ${prefix.trim()} in FFmpeg diagnostics`);
  return line;
}

export async function inspectFfmpeg(
  ffmpeg: ResolvedExecutable,
  ffprobe: ResolvedExecutable,
): Promise<FfmpegCapabilities> {
  const [version, buildconf, encoders, formats, ffprobeVersionOutput, executableSha256] =
    await Promise.all([
      diagnostic(ffmpeg.resolvedPath, ['-version'], 'ffmpeg version inspection'),
      diagnostic(ffmpeg.resolvedPath, ['-buildconf'], 'ffmpeg build inspection'),
      diagnostic(ffmpeg.resolvedPath, ['-encoders'], 'ffmpeg encoder inspection'),
      diagnostic(ffmpeg.resolvedPath, ['-formats'], 'ffmpeg format inspection'),
      diagnostic(ffprobe.resolvedPath, ['-version'], 'ffprobe version inspection'),
      sha256File(ffmpeg.realPath),
    ]);
  return parseFfmpegDiagnostics({
    ffmpeg,
    ffprobe,
    executableSha256,
    version,
    buildconf,
    encoders,
    formats,
    ffprobeVersionOutput,
  });
}

export function parseFfmpegDiagnostics(input: {
  ffmpeg: ResolvedExecutable;
  ffprobe: ResolvedExecutable;
  executableSha256: string;
  version: string;
  buildconf: string;
  encoders: string;
  formats: string;
  ffprobeVersionOutput: string;
}): FfmpegCapabilities {
  const ffmpegVersion = firstLine(input.version, 'ffmpeg version ');
  const ffprobeVersion = firstLine(input.ffprobeVersionOutput, 'ffprobe version ');
  const compilerLine = input.version.split(/\r?\n/).find((line) => line.startsWith('built with '));
  const configurationLine = input.version
    .split(/\r?\n/)
    .find((line) => line.startsWith('configuration: '));
  if (!configurationLine) throw new Error('FFmpeg configuration arguments were not reported');
  const configureArguments = configurationLine.slice('configuration: '.length);
  const capabilities: FfmpegCapabilities = {
    ffmpeg: input.ffmpeg,
    ffprobe: input.ffprobe,
    executableSha256: input.executableSha256,
    ffmpegVersion,
    ffprobeVersion,
    ...(compilerLine ? { compilerLine } : {}),
    configureArguments,
    gplEnabled: configureArguments.includes('--enable-gpl'),
    libx264Enabled: configureArguments.includes('--enable-libx264'),
    libx264EncoderPresent: /^\s*V\S*\s+libx264\s/m.test(input.encoders),
    rawvideoInputPresent: /^\s*D\S*\s+rawvideo\s/m.test(input.formats),
    raw: {
      version: input.version,
      buildconf: input.buildconf,
      encoders: input.encoders,
      formats: input.formats,
      ffprobeVersion: input.ffprobeVersionOutput,
    },
  };
  if (!capabilities.libx264EncoderPresent) {
    throw new Error('System FFmpeg does not provide the required libx264 encoder');
  }
  if (!capabilities.rawvideoInputPresent) {
    throw new Error('System FFmpeg does not provide the required rawvideo input format');
  }
  return capabilities;
}
