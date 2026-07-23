import { readdir, readFile, realpath, stat } from 'node:fs/promises';
import { relative, resolve, sep } from 'node:path';
import { loadDemoPlan } from '../plan/load.js';

export interface DiscoveredPlan {
  path: string;
  valid: boolean;
  name?: string;
  url?: string;
  actionCount?: number;
  actions?: Array<{ ordinal: number; kind: string; target?: string; textLength?: number }>;
  error?: string;
}

function safeRelative(root: string, candidate: string): string {
  const value = relative(root, candidate);
  if (value === '..' || value.startsWith(`..${sep}`) || value.startsWith(sep)) {
    throw new Error('STUDIO_PATH_INVALID');
  }
  return value.split(sep).join('/');
}

function targetDescription(action: Record<string, unknown>): string | undefined {
  const target =
    (action.target as Record<string, unknown> | undefined) ??
    ((action.until as Record<string, unknown> | undefined)?.visible as
      | Record<string, unknown>
      | undefined);
  if (!target) return undefined;
  if (target.role)
    return `role=${target.role}${target.name ? `, name=${JSON.stringify(target.name)}` : ''}`;
  if (target.label) return `label=${JSON.stringify(target.label)}`;
  if (target.testId) return `testId=${JSON.stringify(target.testId)}`;
  if (target.text) return `text=${JSON.stringify(target.text)}`;
  if (target.css) return `css=${JSON.stringify(target.css)}`;
  return undefined;
}

export async function discoverDemoPlans(
  projectRoot: string,
  maximumFiles = 500,
): Promise<DiscoveredPlan[]> {
  const root = await realpath(resolve(projectRoot));
  const directories = ['demos', 'examples'].map((name) => resolve(root, name));
  const files: string[] = [];
  for (const directory of directories) {
    try {
      if (!(await stat(directory)).isDirectory()) continue;
    } catch {
      continue;
    }
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      if (files.length >= maximumFiles) break;
      if (!entry.isFile() || !/\.ya?ml$/iu.test(entry.name) || entry.name.startsWith('.')) continue;
      files.push(resolve(directory, entry.name));
    }
  }
  return Promise.all(
    files.sort().map(async (file): Promise<DiscoveredPlan> => {
      const path = safeRelative(root, file);
      try {
        const [plan, source] = await Promise.all([loadDemoPlan(file), readFile(file, 'utf8')]);
        const input = (await import('js-yaml')).load(source) as {
          actions?: Array<Record<string, unknown>>;
        };
        const actions = (input.actions ?? []).map((action, index) => {
          const target = targetDescription(action);
          return {
            ordinal: index + 1,
            kind: String(action.action),
            ...(target ? { target } : {}),
            ...(action.action === 'type' && typeof action.text === 'string'
              ? { textLength: action.text.length }
              : {}),
          };
        });
        return {
          path,
          valid: true,
          name: plan.name,
          url: plan.initialUrl,
          actionCount: plan.actions.length,
          actions,
        };
      } catch (error) {
        return {
          path,
          valid: false,
          error: error instanceof Error ? error.message.slice(0, 500) : String(error),
        };
      }
    }),
  );
}
