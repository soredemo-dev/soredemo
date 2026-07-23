import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  Menu,
  type MenuItemConstructorOptions,
  nativeTheme,
  shell,
} from 'electron';

// The desktop app is one client of the shared Soredemo engine. It never imports
// engine code statically (the engine is ESM and must never depend on Electron);
// it loads the built programmatic Studio API at runtime and supervises it.
interface StudioServerHandle {
  url: string;
  host: string;
  port: number;
  projectRoot: string;
  close(): Promise<void>;
}
interface EngineModule {
  startStudioServer(options: {
    projectRoot: string;
    host?: string;
    port?: number;
    agent?: 'auto' | 'claude-code' | 'none';
  }): Promise<StudioServerHandle>;
}

const AGENT_MODE = (process.env.SOREDEMO_DESKTOP_AGENT as 'auto' | 'none' | undefined) ?? 'auto';
const SELFTEST_OUT = process.env.SOREDEMO_DESKTOP_SELFTEST;
const PRESET_PROJECT = process.env.SOREDEMO_DESKTOP_PROJECT;
const DIAG = process.env.SOREDEMO_DESKTOP_DIAG === '1';

function diag(message: string): void {
  if (DIAG) process.stderr.write(`[desktop] ${message}\n`);
}

function engineEntry(): string {
  // Packaged builds ship the built engine under resources/engine; dev loads the
  // repository's own dist/ output (run `pnpm build` at the repo root first).
  const packaged = resolve(process.resourcesPath ?? '', 'engine', 'dist', 'studio', 'server.js');
  if (app.isPackaged && existsSync(packaged)) return packaged;
  return resolve(__dirname, '..', '..', 'dist', 'studio', 'server.js');
}

async function loadEngine(): Promise<EngineModule> {
  return (await import(pathToFileURL(engineEntry()).href)) as EngineModule;
}

interface WindowState {
  width: number;
  height: number;
  x?: number;
  y?: number;
}

function stateFile(): string {
  return resolve(app.getPath('userData'), 'window-state.json');
}

function loadWindowState(): WindowState {
  try {
    const parsed = JSON.parse(readFileSync(stateFile(), 'utf8')) as Partial<WindowState>;
    if (typeof parsed.width === 'number' && typeof parsed.height === 'number') {
      return {
        width: parsed.width,
        height: parsed.height,
        ...(typeof parsed.x === 'number' ? { x: parsed.x } : {}),
        ...(typeof parsed.y === 'number' ? { y: parsed.y } : {}),
      };
    }
  } catch {
    // First launch or unreadable state: fall back to defaults.
  }
  return { width: 1280, height: 860 };
}

function persistWindowState(window: BrowserWindow): void {
  if (window.isDestroyed() || window.isMinimized()) return;
  const bounds = window.getBounds();
  try {
    mkdirSync(dirname(stateFile()), { recursive: true });
    writeFileSync(
      stateFile(),
      `${JSON.stringify({ width: bounds.width, height: bounds.height, x: bounds.x, y: bounds.y })}\n`,
    );
  } catch {
    // Persistence is best-effort; never block quit on it.
  }
}

const WEB_PREFERENCES = {
  sandbox: true,
  contextIsolation: true,
  nodeIntegration: false,
  webSecurity: true,
} as const;

let studio: StudioServerHandle | undefined;
let mainWindow: BrowserWindow | undefined;
let studioOrigin: string | undefined;
let quitting = false;

async function stopStudio(): Promise<void> {
  const handle = studio;
  studio = undefined;
  studioOrigin = undefined;
  if (handle) await handle.close();
}

async function pickProjectDirectory(): Promise<string | undefined> {
  const result = await dialog.showOpenDialog({
    title: 'Choose a Soredemo project directory',
    properties: ['openDirectory', 'createDirectory'],
    buttonLabel: 'Open Project',
  });
  if (result.canceled || result.filePaths.length === 0) return undefined;
  return result.filePaths[0];
}

async function openProject(projectRoot: string): Promise<void> {
  diag(`openProject ${projectRoot}`);
  await stopStudio();
  diag(`loading engine from ${engineEntry()}`);
  const engine = await loadEngine();
  studio = await engine.startStudioServer({
    projectRoot,
    host: '127.0.0.1',
    port: 0,
    agent: AGENT_MODE,
  });
  studioOrigin = new URL(studio.url).origin;
  diag(`studio started at ${studio.url}`);
  if (process.env.SOREDEMO_DESKTOP_URL_FILE) {
    writeFileSync(process.env.SOREDEMO_DESKTOP_URL_FILE, `${studio.url}\n`);
  }
  if (!mainWindow || mainWindow.isDestroyed()) createWindow();
  await mainWindow?.loadURL(studio.url);
  diag('window loadURL resolved');
}

function applySecurity(window: BrowserWindow): void {
  // External links and any attempt to navigate away from the local Studio
  // origin are routed to the default browser; the window itself only ever
  // shows loopback Studio content.
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('http://') || url.startsWith('https://')) void shell.openExternal(url);
    return { action: 'deny' };
  });
  window.webContents.on('will-navigate', (event, url) => {
    if (!studioOrigin || new URL(url).origin !== studioOrigin) {
      event.preventDefault();
      if (url.startsWith('http://') || url.startsWith('https://')) void shell.openExternal(url);
    }
  });
}

function createWindow(): void {
  const state = loadWindowState();
  const window = new BrowserWindow({
    width: state.width,
    height: state.height,
    ...(state.x !== undefined && state.y !== undefined ? { x: state.x, y: state.y } : {}),
    minWidth: 960,
    minHeight: 640,
    show: process.env.SOREDEMO_DESKTOP_HIDE_WINDOW !== '1',
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#111317' : '#ffffff',
    title: 'Soredemo Studio',
    webPreferences: {
      preload: resolve(__dirname, 'preload.js'),
      ...WEB_PREFERENCES,
    },
  });
  applySecurity(window);
  const persist = (): void => persistWindowState(window);
  window.on('resize', persist);
  window.on('move', persist);
  window.on('close', persist);
  window.on('closed', () => {
    mainWindow = undefined;
  });
  mainWindow = window;
}

function buildMenu(): void {
  const template: MenuItemConstructorOptions[] = [
    {
      label: app.name,
      submenu: [
        { role: 'about' },
        { type: 'separator' },
        { role: 'hide' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' },
      ],
    },
    {
      label: 'File',
      submenu: [
        {
          label: 'Open Project…',
          accelerator: 'CmdOrCtrl+O',
          click: async () => {
            const chosen = await pickProjectDirectory();
            if (chosen) await openProject(chosen);
          },
        },
      ],
    },
    {
      label: 'Edit',
      submenu: [
        { role: 'undo' },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' },
      ],
    },
    { label: 'Window', role: 'windowMenu' },
    {
      role: 'help',
      submenu: [
        {
          label: 'Soredemo on GitHub',
          click: () => void shell.openExternal('https://github.com/soredemo-dev/soredemo'),
        },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function registerIpc(): void {
  ipcMain.handle('soredemo:getAppVersion', () => app.getVersion());
  ipcMain.handle('soredemo:pickProjectDirectory', async () => {
    const chosen = await pickProjectDirectory();
    if (chosen) await openProject(chosen);
    return chosen ?? null;
  });
}

async function runSelfTest(outPath: string): Promise<void> {
  const window = mainWindow;
  const verdict: Record<string, unknown> = { ok: false };
  try {
    if (!window || !studio) throw new Error('window or studio not initialized');
    verdict.security = { ...WEB_PREFERENCES };
    verdict.loadedUrl = window.webContents.getURL();
    verdict.loadedLoopback =
      verdict.loadedUrl === studio.url || `${studio.url}/` === verdict.loadedUrl;
    verdict.appVersion = app.getVersion();
    verdict.menuPresent = Menu.getApplicationMenu() !== null;
    // Renderer-side surface: exactly the declared bridge, no Node escape hatches,
    // and the session cookie authenticates an API call from within the page.
    verdict.renderer = await window.webContents.executeJavaScript(`(async () => {
      const bridge = globalThis.soredemoDesktop || null;
      const keys = bridge ? Object.keys(bridge).sort() : [];
      const meta = await fetch('/api/meta').then((r) => ({ status: r.status })).catch((e) => ({ error: String(e) }));
      return {
        bridgeKeys: keys,
        hasRequire: typeof globalThis.require !== 'undefined',
        hasProcess: typeof globalThis.process !== 'undefined',
        hasModule: typeof globalThis.module !== 'undefined',
        title: document.title,
        metaStatus: meta.status ?? null,
        metaError: meta.error ?? null,
      };
    })()`);
    const renderer = verdict.renderer as Record<string, unknown>;
    verdict.ok =
      verdict.loadedLoopback === true &&
      renderer.metaStatus === 200 &&
      renderer.hasRequire === false &&
      renderer.hasProcess === false &&
      renderer.hasModule === false &&
      JSON.stringify((renderer as { bridgeKeys: string[] }).bridgeKeys) ===
        JSON.stringify(['getAppVersion', 'pickProjectDirectory']);
  } catch (error) {
    verdict.error = error instanceof Error ? error.message : String(error);
  }
  writeFileSync(outPath, `${JSON.stringify(verdict, null, 2)}\n`);
  quitting = true;
  await stopStudio();
  app.quit();
}

app.on('window-all-closed', () => {
  // macOS convention keeps the app alive without windows; the self-test and an
  // explicit quit both tear the Studio server down first.
  if (process.platform !== 'darwin') app.quit();
});

app.on('before-quit', (event) => {
  if (quitting || !studio) return;
  event.preventDefault();
  quitting = true;
  void stopStudio().finally(() => app.quit());
});

function gracefulSignalShutdown(): void {
  // SIGINT/SIGTERM to the Electron process must stop the Studio server and any
  // active run through the same close() path, leaving no orphan Chromium/FFmpeg
  // and no stale descriptor.
  if (quitting) return;
  quitting = true;
  diag('signal received; shutting down');
  void stopStudio().finally(() => app.exit(0));
}
process.on('SIGINT', gracefulSignalShutdown);
process.on('SIGTERM', gracefulSignalShutdown);

async function bootstrap(): Promise<void> {
  buildMenu();
  registerIpc();
  nativeTheme.themeSource = 'system';
  createWindow();
  const project = PRESET_PROJECT ?? (await pickProjectDirectory()) ?? process.cwd();
  await openProject(project);
  // loadURL resolves once the main frame has finished loading, so the page is
  // ready for inspection here without racing a one-shot did-finish-load listener.
  if (SELFTEST_OUT) {
    diag('running self-test');
    await runSelfTest(SELFTEST_OUT);
  }
}

app
  .whenReady()
  .then(bootstrap)
  .catch((error) => {
    dialog.showErrorBox('Soredemo Studio failed to start', String(error));
    app.quit();
  });
