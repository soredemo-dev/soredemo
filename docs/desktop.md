# Soredemo desktop shell (development foundation)

The `desktop/` package is a **development-grade Electron macOS shell** that
embeds the existing Soredemo Studio vertical slice in a native window. It is a
foundation, **not the finished product**: it is not code-signed, not notarized,
not distributed, and adds no new product features. See
[ADR 0011](adr/0011-electron-desktop-shell.md) for the architecture decision.

## What it is

- A thin Electron **main** process that starts the existing Studio server
  in-process (via the built `startStudioServer` programmatic API — the same one
  the `soredemo studio` CLI command uses), opens **one** sandboxed
  `BrowserWindow` on the loopback Studio URL, and supervises lifecycle.
- The window loads the **unchanged** alpha.1 Studio UI, authenticated by the
  same ephemeral `HttpOnly` session cookie as the browser flow.
- Native macOS shell basics: application menu (About/Quit `Cmd+Q`, a standard
  Edit menu so copy/paste work, Window, Help), a native directory picker to
  choose the project directory, window size/position persistence under the
  app's `userData`, and shell chrome that follows the system appearance.

The full alpha.1 slice runs unchanged inside the window: fake/read-only Agent
proposal → validation → exact plan-hash approval → atomic save → production run
→ ordered SSE events → sampled live preview → MP4 artifact → proof artifact.

## Architecture guarantees

- The production engine never imports Electron (guarded by
  `test/architecture/electron-import-boundary.test.ts`).
- The shell never spawns the CLI to scrape output, never opens a second capture
  path, and never adds a second compositor or preview authority — it is one
  client of the shared engine, exactly like the CLI.
- Renderer security: `sandbox`, `contextIsolation`, `nodeIntegration: false`,
  `webSecurity` on; a narrow typed preload exposes only `getAppVersion` and
  `pickProjectDirectory`; no remote content is loaded; external links open in
  the default browser.
- The shell is **never** shipped in the published `soredemo` npm package.

## Running it (dev)

From the repository root, build the engine first, then run the shell:

```bash
pnpm build                    # builds the engine into dist/
cd desktop
pnpm install                  # installs Electron + electron-builder (dev only)
pnpm build                    # compiles desktop/src to desktop/dist
pnpm start                    # launches the Electron app; pick a project dir
```

On launch the app asks for a project directory (any folder containing a valid
Demo Plan, e.g. the repository's `test/fixtures`). Use **File → Open Project…**
to switch projects.

## Packaging a dev `.app` (unsigned)

```bash
cd desktop
pnpm dist                     # electron-builder --mac --arm64 (dir target)
```

This produces an unsigned, undistributed macOS arm64 `.app` under
`desktop/release/` for local smoke testing only. It stages the built engine and
its runtime dependencies under the app's resources. There is intentionally no
DMG, signing, notarization, or auto-update — those are later release milestones.

## Not implemented here

Manual Web recording, Manual Desktop capture, human takeover, pause/resume, the
timeline editor, narration/audio, mobile support, a design-system UI pass, and
distribution-ready packaging are **not** part of this foundation and are tracked
as later milestones.
