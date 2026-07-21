import { constants } from 'node:fs';
import { access, realpath, stat } from 'node:fs/promises';
import { delimiter, dirname, isAbsolute, join, resolve } from 'node:path';
import type { ResolvedExecutable } from './types.js';

async function executableFile(candidate: string): Promise<boolean> {
  try {
    const entry = await stat(candidate);
    if (!entry.isFile()) return false;
    await access(candidate, process.platform === 'win32' ? constants.F_OK : constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function executableNames(name: string, environment: NodeJS.ProcessEnv): string[] {
  if (process.platform !== 'win32') return [name];
  const extensions = (environment.PATHEXT ?? '.COM;.EXE;.BAT;.CMD').split(';').filter(Boolean);
  return extensions.some((extension) => name.toLowerCase().endsWith(extension.toLowerCase()))
    ? [name]
    : extensions.map((extension) => `${name}${extension.toLowerCase()}`);
}

async function resolved(
  requestedName: string,
  resolvedPath: string,
  source: ResolvedExecutable['source'],
): Promise<ResolvedExecutable> {
  return {
    requestedName,
    resolvedPath,
    realPath: await realpath(resolvedPath),
    source,
  };
}

export async function resolveExecutable(options: {
  name: string;
  environmentVariable?: string;
  environment?: NodeJS.ProcessEnv;
}): Promise<ResolvedExecutable> {
  const environment = options.environment ?? process.env;
  if (options.environmentVariable && options.environmentVariable in environment) {
    const override = environment[options.environmentVariable];
    if (!override) throw new Error(`${options.environmentVariable} must not be empty`);
    const candidate = isAbsolute(override) ? override : resolve(override);
    if (!(await executableFile(candidate))) {
      throw new Error(`${options.environmentVariable} does not point to an executable file`);
    }
    return resolved(options.name, candidate, 'environment');
  }

  for (const directory of (environment.PATH ?? '').split(delimiter).filter(Boolean)) {
    for (const name of executableNames(options.name, environment)) {
      const candidate = join(directory, name);
      if (await executableFile(candidate)) return resolved(options.name, candidate, 'path');
    }
  }
  throw new Error(`${options.name} was not found on PATH`);
}

export async function resolveFfprobe(
  ffmpeg: ResolvedExecutable,
  environment: NodeJS.ProcessEnv = process.env,
): Promise<ResolvedExecutable> {
  for (const name of executableNames('ffprobe', environment)) {
    const sibling = join(dirname(ffmpeg.resolvedPath), name);
    if (await executableFile(sibling)) return resolved('ffprobe', sibling, 'path');
  }
  return resolveExecutable({ name: 'ffprobe', environment });
}
