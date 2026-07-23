// Stages the built Soredemo engine and its production runtime dependencies into
// desktop/engine/ so electron-builder can ship them under the packaged app's
// resources/engine. Dev runs load the repository dist/ directly and never touch
// this. This is a development-build convenience, not a distribution pipeline.
import { cp, mkdir, readFile, rm } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const desktopRoot = resolve(here, '..');
const repoRoot = resolve(desktopRoot, '..');
const stage = resolve(desktopRoot, 'engine');
const require = createRequire(resolve(repoRoot, 'package.json'));

const pkg = JSON.parse(await readFile(resolve(repoRoot, 'package.json'), 'utf8'));
const runtimeDeps = Object.keys(pkg.dependencies ?? {});

await rm(stage, { recursive: true, force: true });
await mkdir(resolve(stage, 'node_modules'), { recursive: true });

await cp(resolve(repoRoot, 'dist'), resolve(stage, 'dist'), { recursive: true, dereference: true });

// Resolve each production dependency (and, transitively, whatever it re-exports)
// from the repository's own resolution graph, dereferencing pnpm symlinks.
const seen = new Set();
async function stageModule(name) {
  if (seen.has(name)) return;
  seen.add(name);
  let entry;
  try {
    entry = require.resolve(`${name}/package.json`);
  } catch {
    return;
  }
  const source = dirname(entry);
  await cp(source, resolve(stage, 'node_modules', name), { recursive: true, dereference: true });
  const depPkg = JSON.parse(await readFile(entry, 'utf8'));
  for (const dep of Object.keys(depPkg.dependencies ?? {})) await stageModule(dep);
}

for (const name of runtimeDeps) await stageModule(name);

process.stdout.write(`Staged engine + ${seen.size} runtime packages into ${stage}\n`);
