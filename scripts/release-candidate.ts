import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { arch, platform } from 'node:os';
import { basename, resolve } from 'node:path';
import { startFixtureServer } from '../test/fixtures/web-app/server.js';
import { runCleanBrowserCacheGate } from './clean-browser-cache-gate.js';
import { auditTarball } from './release-package-audit.js';

const require = createRequire(import.meta.url);
const checkRoot = resolve('.tmp/release-check');
const candidateRoot = resolve('.tmp/release-candidate');
const npmEnvironment = { ...process.env, npm_config_cache: resolve('.tmp/release-npm-cache') };

interface CommandResult {
  code: number | null;
  stdout: string;
  stderr: string;
}

async function command(
  file: string,
  args: string[],
  options: { stream?: boolean; allowFailure?: boolean; env?: NodeJS.ProcessEnv } = {},
): Promise<CommandResult> {
  const child = spawn(file, args, {
    cwd: process.cwd(),
    env: options.env ?? process.env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk: string) => {
    stdout += chunk;
    if (stdout.length > 16_000_000) throw new Error(`${file} stdout exceeded its bound`);
    if (options.stream) process.stdout.write(chunk);
  });
  child.stderr.on('data', (chunk: string) => {
    stderr = `${stderr}${chunk}`.slice(-2_000_000);
    if (options.stream) process.stderr.write(chunk);
  });
  const code = await new Promise<number | null>((accept, reject) => {
    child.once('error', reject);
    child.once('close', accept);
  });
  if (code !== 0 && !options.allowFailure)
    throw new Error(`${file} ${args.join(' ')} failed (${code}): ${stderr}\n${stdout}`);
  return { code, stdout, stderr };
}

const pnpm = (args: string[], stream = true) => command('corepack', ['pnpm', ...args], { stream });

async function git(...args: string[]): Promise<string> {
  return (await command('git', args)).stdout.trim();
}

async function sha256(file: string): Promise<string> {
  return createHash('sha256')
    .update(await readFile(file))
    .digest('hex');
}

function structuredOutput(stdout: string): Record<string, unknown> {
  const offset = stdout.indexOf('{');
  if (offset === -1) throw new Error('Command did not emit a JSON object');
  return JSON.parse(stdout.slice(offset)) as Record<string, unknown>;
}

async function registryStatus(): Promise<Record<string, unknown>> {
  const view = await command(
    'npm',
    ['view', 'soredemo', 'name', 'version', 'maintainers', '--json'],
    {
      allowFailure: true,
      env: npmEnvironment,
    },
  );
  const whoami = await command('npm', ['whoami'], {
    allowFailure: true,
    env: npmEnvironment,
  });
  if (view.code === 0) {
    const packageRecord = JSON.parse(view.stdout) as Record<string, unknown>;
    throw new Error(`npm name soredemo is already registered: ${JSON.stringify(packageRecord)}`);
  }
  if (!view.stderr.includes('E404') && !view.stdout.includes('E404'))
    throw new Error(`npm registry status is unverifiable: ${view.stderr || view.stdout}`);
  return {
    packageName: 'soredemo',
    status: 'unregistered',
    ...(whoami.code === 0 ? { authenticatedAccount: whoami.stdout.trim() } : {}),
  };
}

async function createPack(destination: string): Promise<{ tarball: string; dryRun: unknown }> {
  await rm(destination, { recursive: true, force: true });
  await mkdir(destination, { recursive: true });
  const dry = await command('npm', ['pack', '--dry-run', '--json', '--silent'], {
    env: npmEnvironment,
  });
  const dryRun = JSON.parse(dry.stdout) as unknown;
  const packed = await command(
    'npm',
    ['pack', '--json', '--silent', '--pack-destination', destination],
    { env: npmEnvironment },
  );
  JSON.parse(packed.stdout);
  const names = (await readdir(destination)).filter((name) => name.endsWith('.tgz'));
  if (names.length !== 1 || !names[0])
    throw new Error('npm pack did not create exactly one tarball');
  return { tarball: resolve(destination, names[0]), dryRun };
}

async function runSignalGate(): Promise<void> {
  const server = await fixtureServer();
  try {
    await pnpm(['gate:signals']);
  } finally {
    await server.close();
  }
}

async function runPublicFailureGate(): Promise<Record<string, unknown>> {
  const server = await fixtureServer();
  try {
    const output = resolve(checkRoot, 'should-not-exist.mp4');
    const result = await command(
      process.execPath,
      [
        resolve('dist/cli.js'),
        'render',
        'test/fixtures/missing-target-demo.yaml',
        '--out',
        output,
        '--json',
      ],
      { allowFailure: true },
    );
    if (result.code !== 1)
      throw new Error('Public missing-target gate returned the wrong exit code');
    const parsed = JSON.parse(result.stdout) as Record<string, unknown>;
    if (parsed.code !== 'TARGET_NOT_FOUND') throw new Error('Public missing-target code changed');
    return parsed;
  } finally {
    await server.close();
  }
}

async function fixtureServer(): Promise<{ close(): Promise<void> }> {
  try {
    return await startFixtureServer(4173, resolve('test/fixtures/web-app'));
  } catch (error) {
    if (
      typeof error !== 'object' ||
      error === null ||
      !('code' in error) ||
      (error as { code?: unknown }).code !== 'EADDRINUSE'
    )
      throw error;
    const response = await fetch('http://127.0.0.1:4173/');
    const body = await response.text();
    if (!response.ok || !body.includes('data-testid="demo-ready"'))
      throw new Error('Port 4173 is occupied by something other than the Soredemo fixture');
    return { close: async () => undefined };
  }
}

async function check(): Promise<void> {
  await rm(checkRoot, { recursive: true, force: true });
  await mkdir(checkRoot, { recursive: true });
  const status = await git('status', '--porcelain');
  if (status) throw new Error('release:check requires a clean Git worktree');
  await pnpm(['install', '--frozen-lockfile']);
  await pnpm(['typecheck']);
  await pnpm(['lint']);
  await pnpm(['test']);
  await pnpm(['build']);
  await pnpm(['docs:verify']);
  await command('git', ['diff', '--exit-code', '--', 'schema/soredemo.schema.json']);
  await pnpm(['soredemo', 'validate', 'examples/demo.yaml']);
  const doctorResult = await command('corepack', ['pnpm', 'soredemo', 'doctor', '--json']);
  const goldenResult = await command('corepack', ['pnpm', 'golden:verify'], { stream: true });
  const liveResult = await command('corepack', ['pnpm', 'live-visual:verify'], { stream: true });
  await runSignalGate();
  const failedRender = await runPublicFailureGate();
  const licenses = await command('corepack', ['pnpm', 'licenses', 'list', '--prod', '--json']);
  await writeFile(resolve(checkRoot, 'production-licenses.json'), licenses.stdout);
  const registry = await registryStatus();
  const packed = await createPack(resolve(checkRoot, 'package'));
  await writeFile(
    resolve(checkRoot, 'npm-pack-dry-run.json'),
    `${JSON.stringify(packed.dryRun, null, 2)}\n`,
  );
  const packageAudit = await auditTarball(packed.tarball, resolve(checkRoot, 'extracted'));
  const cleanInstall = await runCleanBrowserCacheGate(packed.tarball);
  const state = {
    schemaVersion: 1,
    gitCommit: await git('rev-parse', 'HEAD'),
    success: true,
    registry,
    doctor: structuredOutput(doctorResult.stdout),
    golden: structuredOutput(goldenResult.stdout),
    liveVisual: structuredOutput(liveResult.stdout),
    packageAudit,
    cleanInstall,
    failedRender,
  };
  await writeFile(resolve(checkRoot, 'state.json'), `${JSON.stringify(state, null, 2)}\n`);
  process.stdout.write(`Release checks passed for ${state.gitCommit}.\n`);
}

function packageVersion(name: string): string {
  return (require(`${name}/package.json`) as { version: string }).version;
}

async function pack(): Promise<void> {
  const state = JSON.parse(await readFile(resolve(checkRoot, 'state.json'), 'utf8')) as {
    gitCommit: string;
    success: boolean;
    registry: Record<string, unknown>;
    doctor: Record<string, unknown>;
  };
  const commit = await git('rev-parse', 'HEAD');
  if (!state.success || state.gitCommit !== commit)
    throw new Error('release:pack requires release:check results for the current commit');
  const worktree = await git('status', '--porcelain');
  if (worktree) throw new Error('release:pack requires a clean Git worktree');
  const packed = await createPack(candidateRoot);
  const audit = await auditTarball(packed.tarball, resolve(candidateRoot, '.inspection'));
  await rm(resolve(candidateRoot, '.inspection'), { recursive: true, force: true });
  const bytes = (await stat(packed.tarball)).size;
  const digest = await sha256(packed.tarball);
  const packageJson = JSON.parse(await readFile('package.json', 'utf8')) as {
    name: string;
    version: string;
    scripts: Record<string, string>;
  };
  const lifecycleNames = new Set([
    'preinstall',
    'install',
    'postinstall',
    'prepack',
    'prepare',
    'postpack',
    'prepublishOnly',
  ]);
  const lifecycleScripts = Object.fromEntries(
    Object.entries(packageJson.scripts).filter(([name]) => lifecycleNames.has(name)),
  );
  const remoteContainsCommit =
    (
      await command('git', ['merge-base', '--is-ancestor', commit, 'origin/main'], {
        allowFailure: true,
      })
    ).code === 0;
  const doctorChecks = state.doctor.checks as Array<Record<string, unknown>>;
  const chromium = doctorChecks.find((check) => check.name === 'chromium');
  const ffmpeg = doctorChecks.find((check) => check.name === 'ffmpeg');
  const manifest = {
    schemaVersion: 1,
    package: {
      name: packageJson.name,
      version: packageJson.version,
      tarball: basename(packed.tarball),
      byteLength: bytes,
      sha256: digest,
      fileCount: audit.files.length,
    },
    source: {
      gitCommit: commit,
      gitBranch: await git('branch', '--show-current'),
      worktreeClean: true,
      remoteContainsCommit,
    },
    environment: {
      nodeVersion: process.versions.node,
      pnpmVersion: (await command('corepack', ['pnpm', '--version'])).stdout.trim(),
      platform: platform(),
      architecture: arch(),
    },
    runtime: {
      playwrightVersion: packageVersion('playwright'),
      chromiumVersion: chromium?.summary,
      chromiumRevision: (chromium?.details as Record<string, unknown> | undefined)
        ?.chromiumRevision,
      canvasVersion: packageVersion('@napi-rs/canvas'),
      ffmpegVersion: ffmpeg?.summary,
    },
    registry: state.registry,
    checks: {
      typecheck: true,
      lint: true,
      tests: true,
      build: true,
      schema: true,
      doctor: true,
      exactGolden: true,
      liveVisual: true,
      packageInspection: true,
      cleanInstall: true,
      packedRender: true,
    },
    lifecycleScripts,
    packageAudit: {
      textFilesScanned: audit.textFilesScanned,
      executableMode: audit.executableMode,
      allowlistedFindings: audit.allowlistedFindings,
    },
  };
  await Promise.all([
    writeFile(resolve(candidateRoot, 'SHA256SUMS'), `${digest}  ${basename(packed.tarball)}\n`),
    writeFile(
      resolve(candidateRoot, 'package-files.json'),
      `${JSON.stringify(audit.files, null, 2)}\n`,
    ),
    writeFile(
      resolve(candidateRoot, 'release-manifest.json'),
      `${JSON.stringify(manifest, null, 2)}\n`,
    ),
    writeFile(
      resolve(candidateRoot, 'npm-pack-dry-run.json'),
      `${JSON.stringify(packed.dryRun, null, 2)}\n`,
    ),
    writeFile(
      resolve(candidateRoot, 'release-check.md'),
      `# Soredemo ${packageJson.version} release candidate\n\nAll source, visual-authority, package, isolated-browser-cache, packed-render, failure, and signal gates passed for \`${commit}\`. No npm publication, Git tag, or GitHub Release was created.\n`,
    ),
  ]);
  process.stdout.write(`${JSON.stringify(manifest, null, 2)}\n`);
}

const mode = process.argv[2];
if (mode === 'check') await check();
else if (mode === 'pack') await pack();
else throw new Error('Expected release-candidate mode: check or pack');
