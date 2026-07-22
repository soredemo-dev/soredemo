import { constants } from 'node:fs';
import { access, mkdir, mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { arch, platform, release } from 'node:os';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createCanvas } from '@napi-rs/canvas';
import { inspectChromiumInstallation } from '../browser/chromium-installation.js';
import { loadCursorAsset } from '../compositor/cursor-asset.js';
import { resolveExecutable, resolveFfprobe } from '../encoder/executable-resolver.js';
import { inspectFfmpeg } from '../encoder/ffmpeg-preflight.js';
import type { ResolvedExecutable } from '../encoder/types.js';

const require = createRequire(import.meta.url);

export interface DoctorCheck {
  name: string;
  required: boolean;
  available: boolean;
  summary: string;
  details?: Record<string, unknown>;
}

export interface DoctorResult {
  success: boolean;
  checks: DoctorCheck[];
  warnings: Array<{ code: string; message: string }>;
}

async function packageVersion(name: string): Promise<string> {
  const json = JSON.parse(await readFile(require.resolve(`${name}/package.json`), 'utf8')) as {
    version: string;
  };
  return json.version;
}

export async function runDoctor(): Promise<DoctorResult> {
  const checks: DoctorCheck[] = [];
  const warnings: DoctorResult['warnings'] = [];
  const [nodeMajor, nodeMinor, nodePatch] = process.versions.node.split('.').map(Number);
  checks.push({
    name: 'node',
    required: true,
    available:
      nodeMajor === 20 &&
      ((nodeMinor ?? 0) > 19 || ((nodeMinor ?? 0) === 19 && (nodePatch ?? 0) >= 4)),
    summary: `Node ${process.versions.node}`,
    details: {
      version: process.version,
      platform: `${platform()} ${release()}`,
      architecture: arch(),
    },
  });

  try {
    const ffmpeg = await resolveExecutable({
      name: 'ffmpeg',
      environmentVariable: 'SOREDEMO_FFMPEG_PATH',
    });
    let ffprobe: ResolvedExecutable | undefined;
    try {
      ffprobe = await resolveFfprobe(ffmpeg);
    } catch (error) {
      checks.push({
        name: 'ffprobe',
        required: true,
        available: false,
        summary: error instanceof Error ? error.message : String(error),
      });
    }
    if (ffprobe) {
      const capabilities = await inspectFfmpeg(ffmpeg, ffprobe);
      checks.push(
        {
          name: 'ffmpeg',
          required: true,
          available: capabilities.libx264EncoderPresent && capabilities.rawvideoInputPresent,
          summary: `${capabilities.ffmpegVersion} with libx264`,
          details: {
            path: ffmpeg.resolvedPath,
            realPath: ffmpeg.realPath,
            libx264: capabilities.libx264EncoderPresent,
            rawvideo: capabilities.rawvideoInputPresent,
            gplEnabled: capabilities.gplEnabled,
          },
        },
        {
          name: 'ffprobe',
          required: true,
          available: true,
          summary: capabilities.ffprobeVersion,
          details: { path: ffprobe.resolvedPath, realPath: ffprobe.realPath },
        },
      );
      if (capabilities.gplEnabled || capabilities.libx264Enabled) {
        warnings.push({
          code: 'SYSTEM_FFMPEG_GPL_BUILD',
          message: 'The detected system FFmpeg build is GPL-conditioned and includes libx264.',
        });
      }
    }
  } catch (error) {
    checks.push({
      name: 'ffmpeg',
      required: true,
      available: false,
      summary: error instanceof Error ? error.message : String(error),
    });
  }

  try {
    const installation = await inspectChromiumInstallation();
    checks.push({
      name: 'chromium',
      required: true,
      available: installation.installed,
      summary: installation.installed
        ? `Playwright ${installation.playwrightVersion}, Chromium revision ${installation.chromiumRevision}`
        : (installation.message ?? 'Playwright Chromium is not installed'),
      details: {
        ...(installation.installed ? {} : { code: 'CHROMIUM_NOT_INSTALLED' }),
        playwrightVersion: installation.playwrightVersion,
        chromiumRevision: installation.chromiumRevision,
        executable: installation.executablePath,
        playwrightBrowsersPath: installation.browsersPath,
        installCommand: installation.installCommand,
        launchArguments: ['--force-device-scale-factor=2'],
        viewport: { width: 1440, height: 900 },
        deviceScaleFactor: 2,
        captureScaleProof: 'cdp-screencast-css-color-bands',
      },
    });
    if (installation.installed)
      warnings.push({
        code: 'CAPTURE_VERSION_SENSITIVE',
        message: 'The genuine-2x CDP capture path is pinned and verified at render startup.',
      });
  } catch (error) {
    checks.push({
      name: 'chromium',
      required: true,
      available: false,
      summary: error instanceof Error ? error.message : String(error),
    });
  }

  try {
    const canvas = createCanvas(2, 2);
    const bytes = canvas.data();
    checks.push({
      name: 'canvas',
      required: true,
      available: bytes.byteLength === 16,
      summary: `@napi-rs/canvas ${await packageVersion('@napi-rs/canvas')}`,
      details: { rgbaProbeBytes: bytes.byteLength },
    });
  } catch (error) {
    checks.push({
      name: 'canvas',
      required: true,
      available: false,
      summary: error instanceof Error ? error.message : String(error),
    });
  }

  try {
    const assetFile = fileURLToPath(new URL('../../assets/cursor.svg', import.meta.url));
    const asset = await loadCursorAsset(assetFile);
    checks.push({
      name: 'cursor-asset',
      required: true,
      available: true,
      summary: `Cursor ${asset.definition.renderedWidth}x${asset.definition.renderedHeight}`,
      details: { file: assetFile, sha256: asset.sha256 },
    });
  } catch (error) {
    checks.push({
      name: 'cursor-asset',
      required: true,
      available: false,
      summary: error instanceof Error ? error.message : String(error),
    });
  }

  try {
    const owner = resolve(process.cwd(), '.soredemo');
    await access(process.cwd(), constants.W_OK);
    await mkdir(owner, { recursive: true });
    const directory = await mkdtemp(resolve(owner, 'doctor-'));
    await stat(directory);
    await rm(directory, { recursive: true, force: true });
    checks.push({
      name: 'workspace',
      required: true,
      available: true,
      summary: `Writable workspace: ${owner}`,
    });
  } catch (error) {
    checks.push({
      name: 'workspace',
      required: true,
      available: false,
      summary: error instanceof Error ? error.message : String(error),
    });
  }

  return {
    success: checks.every((check) => !check.required || check.available),
    checks,
    warnings,
  };
}
