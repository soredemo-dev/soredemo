import { randomBytes } from 'node:crypto';
import { mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { dirname, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

export interface BootstrapFile {
  path: string;
  status: 'create' | 'exists';
  content: string;
}

export interface BootstrapPlan {
  projectRoot: string;
  files: BootstrapFile[];
}

const CONFIG = `version: 1

browser:
  viewport:
    width: 1440
    height: 900
  deviceScaleFactor: 2

output:
  width: 1920
  height: 1080
  fps: 30

defaults:
  style: studio
  pace: balanced
`;

const PLAN = `version: 1
name: getting-started
url: http://127.0.0.1:3000

intent:
  goal: Show one successful product workflow

style:
  preset: studio
  pace: balanced

actions:
  - action: wait
    until:
      visible:
        testId: demo-ready
  - action: click
    target:
      role: button
      name: Get started
`;

function inside(root: string, candidate: string): boolean {
  const path = relative(root, candidate);
  return path === '' || (!path.startsWith(`..${sep}`) && path !== '..' && !path.startsWith(sep));
}

async function exists(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile();
  } catch {
    return false;
  }
}

export async function planProjectBootstrap(directory: string): Promise<BootstrapPlan> {
  const projectRoot = resolve(directory);
  const skill = await readFile(
    fileURLToPath(new URL('../../assets/soredemo-skill/SKILL.md', import.meta.url)),
    'utf8',
  );
  const entries = [
    ['soredemo.config.yaml', CONFIG],
    ['demos/getting-started.yaml', PLAN],
    ['.agents/skills/soredemo/SKILL.md', skill],
  ] as const;
  const files = await Promise.all(
    entries.map(async ([path, content]) => ({
      path,
      status: (await exists(resolve(projectRoot, path)))
        ? ('exists' as const)
        : ('create' as const),
      content,
    })),
  );
  return { projectRoot, files };
}

export async function applyProjectBootstrap(plan: BootstrapPlan): Promise<string[]> {
  const created: string[] = [];
  try {
    for (const file of plan.files) {
      if (file.status === 'exists') continue;
      const target = resolve(plan.projectRoot, file.path);
      if (!inside(plan.projectRoot, target)) throw new Error('Bootstrap path escaped project root');
      await mkdir(dirname(target), { recursive: true });
      const temporary = `${target}.${randomBytes(8).toString('hex')}.tmp`;
      await writeFile(temporary, file.content, { flag: 'wx' });
      try {
        if (await exists(target)) throw new Error(`Refusing to overwrite ${file.path}`);
        await rename(temporary, target);
      } catch (error) {
        await rm(temporary, { force: true });
        throw error;
      }
      created.push(target);
    }
    return created;
  } catch (error) {
    await Promise.all(created.map((path) => rm(path, { force: true })));
    throw error;
  }
}
