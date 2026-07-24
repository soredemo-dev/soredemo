# 12. React + Vite for the Studio UI

Status: accepted

## Context

The alpha.1 Studio UI is a single hand-authored `studio/public/index.html` plus
one imperative `studio.js` and a flat `studio.css`. It was the right size for a
vertical slice, but the long-term product needs a componentized UI: a track-based
timeline editor, per-action evidence, multiple run/authoring modes, and a
Screen Studio-class visual design. Hand-rolled DOM manipulation does not scale to
that, and the current UI is at its smallest, cheapest migration point.

This is a deliberate framework decision, not a side effect of the Day-17 Electron
shell. Both clients — the browser `soredemo studio` command and the Electron
window — load the **same** bundled static UI from the **same** Studio server mount
point, and must continue to.

## Decision

Adopt **React + Vite + TypeScript** for the Studio UI, under strict constraints:

- **The server does not learn about Vite.** Vite builds static assets into
  `studio/public` (the location `finalize-dist` already copies into
  `dist/studio/public`). The server still serves flat files from its public root
  and rewrites `/assets/<file>` → `<publicRoot>/<file>`; the build is configured
  with `base: '/assets/'` and `assetsDir: ''` to match, and emits **no inline
  scripts or styles** (the server CSP is `script-src 'self'; style-src 'self'`).
  Session auth, origin checks, and the event protocol are untouched.
- **`studio/public` is generated, not committed** (gitignored). The root `build`
  runs the UI build before `finalize-dist`; a `pretest` builds it so
  `server.test.ts` has the served shell. The npm package still ships only built
  static assets in `dist` — the `files` allowlist is unchanged and React/Vite are
  devDependencies bundled into the emitted JS, never shipped as runtime deps.
- **Runtime dependency policy.** Added devDependencies, all permissive:
  - `react` / `react-dom` (MIT) — the UI runtime, bundled into the static JS.
  - `vite` (MIT) + `@vitejs/plugin-react` (MIT) — build tooling.
  - `@types/react` / `@types/react-dom` (MIT) — types.
  No UI kit, no CSS framework (hand-rolled CSS with design tokens — see
  `docs/design-system.md`), no state-management library (React built-ins only).
- **No remote resources.** System fonts only; no runtime font fetch, no CDN, no
  telemetry — required for the loopback security posture and offline use.

## Consequences

- The UI is componentized (`PlanRail`, `ActionStep`, `ProofBadge`, `ChatPanel`,
  `PreviewStage`, `StatusBar`, `Glyph`) for future milestones, with functional
  parity to the alpha.1 UI: every endpoint, SSE event, flow, error surface, and
  security behavior is preserved.
- The pre-React `test/studio/ui.test.ts` (which grepped static HTML) is replaced
  by React component render tests; `server.test.ts`'s served-page assertion is
  adapted to the SPA shell (`<title>` + `#root`). No security assertion changed.
- Dark theme only for now; a light theme is future work.

## Provenance

Layout patterns (a three-zone editor: authoring / stage / inspector, plus a
status bar) were informed by studying **OpenScreen (MIT)** and the Screen Studio
product as UX references. No code, CSS, or assets were copied from either; the
implementation and the visual language (brand navy, the そ glyph, the
cursor-spark blue accent, the plan-rail "verified checklist" identity) are
Soredemo's own, drawn from the `soredemo-vector-brand` assets.
