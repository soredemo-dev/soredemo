import { createHash, randomBytes } from 'node:crypto';
import { mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { dirname, relative, resolve, sep } from 'node:path';
import { dump, load } from 'js-yaml';
import { type ProposedDemo, ProposedDemoSchema } from '../agent/types.js';
import { parseDemoPlan } from '../plan/load.js';

export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => `${JSON.stringify(key)}:${canonicalJson(item)}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

export function planSha256(plan: unknown): string {
  return createHash('sha256').update(canonicalJson(plan)).digest('hex');
}

export class PlanApproval {
  private approvedHash: string | undefined;
  approve(plan: unknown): string {
    this.approvedHash = planSha256(plan);
    return this.approvedHash;
  }
  isApproved(plan: unknown): boolean {
    return this.approvedHash === planSha256(plan);
  }
  invalidate(): void {
    this.approvedHash = undefined;
  }
}

export function validateProposal(input: unknown): ProposedDemo {
  const proposal = ProposedDemoSchema.parse(input);
  parseDemoPlan(proposal.plan);
  return proposal;
}

function inside(root: string, path: string): boolean {
  const local = relative(root, path);
  return local !== '..' && !local.startsWith(`..${sep}`) && !local.startsWith(sep);
}

export async function saveApprovedPlan(options: {
  projectRoot: string;
  relativePath: string;
  proposal: ProposedDemo;
  approvedHash: string;
}): Promise<{ path: string; sha256: string }> {
  const root = resolve(options.projectRoot);
  const target = resolve(root, options.relativePath);
  if (!inside(root, target) || !/\.ya?ml$/iu.test(target))
    throw new Error('STUDIO_PATH_INVALID: Plan path must remain inside the project and use YAML');
  if (planSha256(options.proposal.plan) !== options.approvedHash)
    throw new Error('Plan changed after approval');
  try {
    await stat(target);
    throw new Error(`Refusing to overwrite existing plan: ${options.relativePath}`);
  } catch (error) {
    if (error instanceof Error && !('code' in error && error.code === 'ENOENT')) throw error;
  }
  const source = dump(options.proposal.plan, { noRefs: true, lineWidth: 100, sortKeys: false });
  parseDemoPlan(load(source));
  await mkdir(dirname(target), { recursive: true });
  const temporary = `${target}.${randomBytes(8).toString('hex')}.tmp`;
  await writeFile(temporary, source, { flag: 'wx' });
  try {
    await rename(temporary, target);
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
  const bytes = await readFile(target);
  return { path: target, sha256: createHash('sha256').update(bytes).digest('hex') };
}
