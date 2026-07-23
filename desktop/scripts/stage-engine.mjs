// Stages the built Soredemo engine and its production runtime dependencies into
// desktop/engine/ so electron-builder can ship them under the packaged app's
// resources/engine. Dev runs load the repository dist/ directly and never touch
// this. This is a development-build convenience, not a distribution pipeline.
import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const desktopRoot = resolve(here, '..');
const repoRoot = resolve(desktopRoot, '..');
const stage = resolve(desktopRoot, 'engine');

const pkg = JSON.parse(await readFile(resolve(repoRoot, 'package.json'), 'utf8'));
const runtimeDeps = Object.keys(pkg.dependencies ?? {});

await rm(stage, { recursive: true, force: true });
await mkdir(resolve(stage, 'node_modules'), { recursive: true });

// The engine dist is ESM; the staged tree needs its own package.json declaring
// `type: module` (and the runtime deps) so Node resolves it as ESM and finds
// the staged node_modules when the packaged app dynamically imports it.
// Keep the engine's own name/version: the runtime reads ../../package.json and
// requires name === 'soredemo' with a string version.
await writeFile(
  resolve(stage, 'package.json'),
  `${JSON.stringify(
    {
      name: pkg.name,
      version: pkg.version,
      private: true,
      type: 'module',
      dependencies: pkg.dependencies ?? {},
    },
    null,
    2,
  )}\n`,
);

await cp(resolve(repoRoot, 'dist'), resolve(stage, 'dist'), { recursive: true, dereference: true });

// Flatten each production dependency and its transitive deps into
// engine/node_modules, dereferencing pnpm symlinks. Children are resolved from
// their parent package's own location because pnpm does not hoist transitive
// dependencies to the top-level node_modules.
const seen = new Set();
async function stageModule(name, fromDir) {
  if (seen.has(name)) return;
  const req = createRequire(resolve(fromDir, 'package.json'));
  // Derive the package root from its resolved entry — packages with a strict
  // `exports` map (e.g. bezier-js) forbid resolving `<name>/package.json`.
  let source;
  try {
    const entry = req.resolve(name);
    const marker = `node_modules/${name}`;
    const index = entry.lastIndexOf(marker);
    if (index === -1) return;
    source = entry.slice(0, index + marker.length);
  } catch {
    return;
  }
  seen.add(name);
  await cp(source, resolve(stage, 'node_modules', name), { recursive: true, dereference: true });
  const depPkg = JSON.parse(await readFile(resolve(source, 'package.json'), 'utf8'));
  // Include optionalDependencies for platform-specific native bindings (e.g.
  // @napi-rs/canvas-darwin-arm64); bindings for other platforms simply fail to
  // resolve and are skipped.
  const children = { ...(depPkg.dependencies ?? {}), ...(depPkg.optionalDependencies ?? {}) };
  for (const dep of Object.keys(children)) await stageModule(dep, source);
}

for (const name of runtimeDeps) await stageModule(name, repoRoot);

process.stdout.write(`Staged engine + ${seen.size} runtime packages into ${stage}\n`);
