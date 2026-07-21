import { readFile, stat } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { load } from 'js-yaml';
import { z } from 'zod';

const ConfigSchema = z.strictObject({
  version: z.literal(1),
  app: z
    .object({
      command: z.string().optional(),
      url: z.string().optional(),
      ready: z.object({ path: z.string() }).optional(),
    })
    .optional(),
  browser: z
    .object({
      viewport: z
        .object({ width: z.number().int().positive(), height: z.number().int().positive() })
        .optional(),
      deviceScaleFactor: z.number().positive().optional(),
    })
    .optional(),
  output: z
    .object({
      width: z.number().int().positive().optional(),
      height: z.number().int().positive().optional(),
      fps: z.number().int().positive().optional(),
    })
    .optional(),
  defaults: z
    .object({
      style: z.literal('studio').optional(),
      pace: z.enum(['fast', 'balanced', 'calm']).optional(),
    })
    .optional(),
  temporaryDirectory: z.string().min(1).optional(),
  auth: z.object({ storageState: z.string().optional() }).optional(),
});

export interface ProjectConfiguration {
  file?: string;
  directory: string;
  viewport?: { width: number; height: number };
  deviceScaleFactor: number;
  output: { width: 1920; height: 1080; fps: 30 };
  runsDirectory: string;
}

async function findConfig(startDirectory: string): Promise<string | undefined> {
  let current = resolve(startDirectory);
  while (true) {
    const candidate = resolve(current, 'soredemo.config.yaml');
    try {
      if ((await stat(candidate)).isFile()) return candidate;
    } catch {}
    const parent = dirname(current);
    if (parent === current) return undefined;
    current = parent;
  }
}

export async function loadProjectConfiguration(planFile: string): Promise<ProjectConfiguration> {
  const planDirectory = dirname(resolve(planFile));
  const file = await findConfig(planDirectory);
  if (!file) {
    return {
      directory: planDirectory,
      deviceScaleFactor: 2,
      output: { width: 1920, height: 1080, fps: 30 },
      runsDirectory: resolve(planDirectory, '.soredemo/runs'),
    };
  }
  const result = ConfigSchema.safeParse(load(await readFile(file, 'utf8')));
  if (!result.success)
    throw new Error(
      `CONFIG_INVALID: ${result.error.issues[0]?.message ?? 'Invalid project configuration'}`,
    );
  const config = result.data;
  if (config.browser?.deviceScaleFactor !== undefined && config.browser.deviceScaleFactor !== 2)
    throw new Error('CONFIG_INVALID: v0.1 deviceScaleFactor must be 2');
  if (
    (config.output?.width ?? 1920) !== 1920 ||
    (config.output?.height ?? 1080) !== 1080 ||
    (config.output?.fps ?? 30) !== 30
  )
    throw new Error('CONFIG_INVALID: v0.1 output must be 1920x1080 at 30fps');
  const directory = dirname(file);
  return {
    file,
    directory,
    ...(config.browser?.viewport ? { viewport: config.browser.viewport } : {}),
    deviceScaleFactor: 2,
    output: { width: 1920, height: 1080, fps: 30 },
    runsDirectory: resolve(directory, config.temporaryDirectory ?? '.soredemo/runs'),
  };
}
