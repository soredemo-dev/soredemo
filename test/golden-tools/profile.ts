import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFile, stat } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { release } from 'node:os';
import { resolve } from 'node:path';
import { promisify } from 'node:util';
import { CLICK_RIPPLE_STYLE } from '../../src/compositor/click-feedback-track.js';
import { STUDIO_CURSOR } from '../../src/compositor/cursor-asset.js';
import {
  STUDIO_BROWSER_CONTENT_RECT,
  STUDIO_BROWSER_WINDOW_RECT,
  STUDIO_GRADIENT,
  STUDIO_TOOLBAR,
  STUDIO_TOOLBAR_HEIGHT,
  STUDIO_TRAFFIC_LIGHTS,
  STUDIO_WINDOW_BORDER,
  STUDIO_WINDOW_RADIUS,
  STUDIO_WINDOW_SHADOW,
} from '../../src/compositor/studio-layout.js';
import { type ExactGoldenProfile, GoldenError } from './types.js';

const require = createRequire(import.meta.url);
const execFileAsync = promisify(execFile);

export const OFFICIAL_EXACT_PROFILE_NAME = 'macos-arm64-canvas-1.0.2' as const;

export async function inspectExactProfile(): Promise<ExactGoldenProfile> {
  const [operatingSystem, canvas, cursor] = await Promise.all([
    operatingSystemIdentity(),
    packageVersion('@napi-rs/canvas'),
    readFile(resolve('assets/cursor.svg')),
  ]);
  return {
    name: OFFICIAL_EXACT_PROFILE_NAME,
    platform: process.platform,
    architecture: process.arch,
    osVersion: operatingSystem.version,
    osBuild: operatingSystem.build,
    nodeVersion: process.versions.node,
    canvasVersion: canvas,
    nativeCanvasPackage: await nativeCanvasIdentity(canvas),
    cursorSvgSha256: sha256(cursor),
    studioConstantsSha256: studioConstantsSha256(),
  };
}

export function officialExactProfile(runtime: ExactGoldenProfile): boolean {
  return (
    runtime.name === OFFICIAL_EXACT_PROFILE_NAME &&
    runtime.platform === 'darwin' &&
    runtime.architecture === 'arm64' &&
    runtime.osVersion === '26.5.2' &&
    runtime.osBuild === '25F84' &&
    runtime.nodeVersion === '20.19.4' &&
    runtime.canvasVersion === '1.0.2' &&
    runtime.nativeCanvasPackage === '@napi-rs/canvas-darwin-arm64@1.0.2'
  );
}

export function requireOfficialExactProfile(runtime: ExactGoldenProfile): void {
  if (!officialExactProfile(runtime)) {
    throw new GoldenError(
      'GOLDEN_PROFILE_MISMATCH',
      'Exact pixel comparison requires the official macOS arm64 Canvas profile',
      { runtime },
    );
  }
}

export function studioConstantsSha256(): string {
  return sha256(
    Buffer.from(
      stableJson({
        content: STUDIO_BROWSER_CONTENT_RECT,
        window: STUDIO_BROWSER_WINDOW_RECT,
        gradient: STUDIO_GRADIENT,
        toolbar: STUDIO_TOOLBAR,
        toolbarHeight: STUDIO_TOOLBAR_HEIGHT,
        trafficLights: STUDIO_TRAFFIC_LIGHTS,
        border: STUDIO_WINDOW_BORDER,
        radius: STUDIO_WINDOW_RADIUS,
        shadow: STUDIO_WINDOW_SHADOW,
        ripple: CLICK_RIPPLE_STYLE,
        cursor: STUDIO_CURSOR,
      }),
    ),
  );
}

async function packageVersion(name: string): Promise<string> {
  const json = JSON.parse(await readFile(require.resolve(`${name}/package.json`), 'utf8')) as {
    version: string;
  };
  return json.version;
}

async function nativeCanvasIdentity(version: string): Promise<string> {
  if (process.platform !== 'darwin' || process.arch !== 'arm64') {
    return `@napi-rs/canvas-${process.platform}-${process.arch}@${version}`;
  }
  const packageFile = resolve(
    `node_modules/.pnpm/@napi-rs+canvas-darwin-arm64@${version}/node_modules/@napi-rs/canvas-darwin-arm64/package.json`,
  );
  try {
    if (!(await stat(packageFile)).isFile()) return 'unavailable';
    const json = JSON.parse(await readFile(packageFile, 'utf8')) as { version: string };
    return `@napi-rs/canvas-darwin-arm64@${json.version}`;
  } catch {
    return 'unavailable';
  }
}

async function operatingSystemIdentity(): Promise<{ version: string; build: string }> {
  if (process.platform !== 'darwin') return { version: release(), build: release() };
  const [{ stdout: version }, { stdout: build }] = await Promise.all([
    execFileAsync('/usr/bin/sw_vers', ['-productVersion']),
    execFileAsync('/usr/bin/sw_vers', ['-buildVersion']),
  ]);
  return { version: version.trim(), build: build.trim() };
}

export function stableJson(value: unknown): string {
  return `${JSON.stringify(sort(value), null, 2)}\n`;
}

function sort(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sort);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => [key, sort(item)]),
  );
}

export function sha256(value: Uint8Array): string {
  return createHash('sha256').update(value).digest('hex');
}
