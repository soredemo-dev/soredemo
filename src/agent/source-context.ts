import type { Stats } from 'node:fs';
import { readdir, readFile, stat } from 'node:fs/promises';
import { relative, resolve, sep } from 'node:path';

const MAX_FILES = 30;
const MAX_FILE_BYTES = 32 * 1024;
const MAX_TOTAL_BYTES = 128 * 1024;
const TEXT_EXTENSIONS = /\.(?:md|json|ya?ml|tsx?|jsx?)$/iu;

function inside(root: string, path: string): boolean {
  const local = relative(root, path);
  return (
    local === '' || (local !== '..' && !local.startsWith(`..${sep}`) && !local.startsWith(sep))
  );
}

export async function collectApprovedSourceContext(options: {
  projectRoot: string;
  includePlansAndTests: boolean;
}): Promise<Array<{ path: string; content: string; truncated: boolean }>> {
  const root = resolve(options.projectRoot);
  const roots = ['README.md', 'package.json', 'src', 'app', 'pages', 'routes'];
  if (options.includePlansAndTests) roots.push('demos', 'test', 'tests');
  const candidates: string[] = [];

  async function visit(path: string, depth: number): Promise<void> {
    if (candidates.length >= MAX_FILES || depth > 4 || !inside(root, path)) return;
    let info: Stats;
    try {
      info = await stat(path);
    } catch {
      return;
    }
    if (info.isFile()) {
      if (TEXT_EXTENSIONS.test(path) && !/(?:^|\/)\.env(?:\.|$)/u.test(path)) candidates.push(path);
      return;
    }
    if (!info.isDirectory()) return;
    for (const entry of await readdir(path, { withFileTypes: true })) {
      if (
        candidates.length >= MAX_FILES ||
        entry.name.startsWith('.') ||
        ['node_modules', 'dist', 'build', 'coverage', 'output'].includes(entry.name)
      )
        continue;
      await visit(resolve(path, entry.name), depth + 1);
    }
  }

  for (const name of roots) await visit(resolve(root, name), 0);
  let total = 0;
  const output: Array<{ path: string; content: string; truncated: boolean }> = [];
  for (const path of candidates.sort()) {
    if (total >= MAX_TOTAL_BYTES) break;
    const bytes = await readFile(path);
    const available = Math.min(MAX_FILE_BYTES, MAX_TOTAL_BYTES - total);
    const slice = bytes.subarray(0, available);
    total += slice.byteLength;
    output.push({
      path: relative(root, path).split(sep).join('/'),
      content: slice.toString('utf8'),
      truncated: slice.byteLength < bytes.byteLength,
    });
  }
  return output;
}
