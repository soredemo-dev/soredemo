# 11. Electron desktop shell, macOS-first, thin main over the shared engine

Status: accepted

## Context

Soredemo's long-term product is an agent-native desktop Product Demo Studio.
alpha.1 shipped a local **browser** Studio vertical slice: a loopback HTTP
server (`startStudioServer`) with an ephemeral session cookie, a shared
`RunCoordinator`, versioned SSE run events, a production-derived sampled
preview, an artifact registry, and portable proof bundles. It is opened today
with `soredemo studio`, which loads the bundled static UI in the system
browser.

We need a real desktop application: a native window, native menus, native
dialogs, and native lifecycle — at a quality bar comparable to Screen Studio,
which is itself an Electron application. We must add this **without** turning
the desktop shell into a second renderer or letting it leak into the engine.

## Decision

The desktop shell is **Electron**, targeting **macOS arm64 first** as the only
polish target for now. Windows and Linux are explicitly deferred with no
commitments.

The shell is architected as a thin client of the existing engine contracts:

- **Thin main process.** Electron main only does shell concerns: create one
  `BrowserWindow`, build the native application menu, own native dialogs,
  supervise lifecycle, and start/stop the Studio server. It contains no
  production logic.
- **Sandboxed renderer.** `sandbox: true`, `contextIsolation: true`,
  `nodeIntegration: false`, `webSecurity: true`. The renderer is the existing
  server-hosted static Studio UI, loaded from the loopback URL and
  authenticated by the same `HttpOnly; SameSite=Strict` session cookie the
  browser flow uses. No remote content is ever loaded; `window.open` and
  off-origin navigation are denied and routed to the default browser.
- **Narrow typed preload.** A CommonJS, sandbox-compatible preload exposes
  exactly `getAppVersion` and `pickProjectDirectory` over `contextBridge` and
  `ipcRenderer.invoke`. Nothing else — no Node, no filesystem, no engine.
- **Engine reached only through programmatic APIs.** Main loads the built
  `startStudioServer` (ESM) at runtime via dynamic `import()` and supervises
  its handle. It never spawns the CLI to scrape terminal output, never opens a
  second capture path, and never adds a second compositor or preview authority.
- **Engine independence is enforced.** No `electron` import may appear anywhere
  under `src/` (guarded by `test/architecture/electron-import-boundary.test.ts`).
  The engine already exposed `startStudioServer`, which the CLI `studio` command
  also calls, so no new engine seam was required — the CLI and the desktop shell
  are two clients of one authority.
- **The desktop app is never published in the `soredemo` npm package.** It
  lives in a separate, unpublished `desktop/` package with its own Electron and
  electron-builder devDependencies; the package `files` allowlist excludes it,
  keeping the published surface at its established file set.

## Consequences

- The CLI and browser `soredemo studio` flows are unchanged; the desktop shell
  reuses the identical runner, compositor, encoder, and proof engine, so a
  render produced in the desktop window is the same artifact the CLI produces.
- Lifecycle (menu quit, Cmd+Q, window close, SIGINT/SIGTERM) tears down the
  Studio server through the existing `handle.close()` path, which stops active
  runs via the coordinator — leaving no orphan Chromium/FFmpeg processes and no
  stale `.soredemo/studio.json` descriptor, consistent with the existing signal
  gate.
- Native modules are N-API (`@napi-rs/canvas`) or spawn external binaries
  (Playwright's Chromium, system FFmpeg), so the engine runs inside Electron's
  Node without an ABI rebuild.
- This is a **development foundation**, not the finished product. Code signing,
  notarization, DMG distribution, auto-update, a design-system UI pass, and the
  future Manual/Import/Mobile modes and timeline editor are explicitly out of
  scope here and remain later milestones.

## Provenance

The desktop split (thin main, isolated renderer, electron-builder packaging on
macOS with `extendInfo`, per-window `webPreferences`) reflects patterns learned
from **OpenScreen (MIT, © 2025 Siddharth Vaddem)**, studied as read-only
reference. No OpenScreen code, assets, or configuration were copied, and its
PixiJS rendering pipeline was deliberately not consulted for Soredemo's
compositor. Soredemo's shell is stricter than the reference: it additionally
enables the renderer `sandbox`, restricts the preload to two typed methods, and
keeps the production engine entirely free of Electron.
