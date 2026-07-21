# Soredemo repository guide

Soredemo is a single-package, MIT-licensed Node.js CLI that compiles declarative YAML Demo Plans into polished product-demo videos of real web applications.

Development uses Node.js 20 or later and the exact `pnpm@10.34.0` version declared in `package.json`. Use Corepack so the documented minimum Node runtime can execute every project command.

## Commands

```bash
pnpm typecheck
pnpm lint
pnpm lint:fix
pnpm test
pnpm build
pnpm soredemo validate examples/demo.yaml
pnpm spike:day2
pnpm spike:day3
```

## Source boundaries

- `src/plan/` owns author input schemas, YAML loading, diagnostics, and normalized plans.
- `src/cli/` owns command registration, exit codes, and stdout/stderr behavior.
- `src/schema/` generates the checked-in JSON Schema.
- Validation must not import or initialize Playwright, Chromium, canvas, capture, compositor, or encoder modules.
- Browser capture, composition, and encoding are separate pipeline phases and must remain separate modules.

## Working agreements

- Do not add dependencies casually.
- Propose every dependency not explicitly approved in the product specification.
- Runtime dependencies must use permissive licenses. Remotion is banned from the dependency tree.
- Default to writing no code comments.
- Add comments only for non-obvious reasons, constraints, or workarounds.
- Use small commits.
- Use Conventional Commits.
- Keep module responsibilities narrow.
- Prefer explicit data contracts over loosely typed objects.
- Do not add abstractions that are unused by the current phase.
- Do not hide spike failures behind fallbacks.
- Keep `TODO.md` current at the end of every session.
- Check off completed work.
- Record what failed or behaved unexpectedly.
- Machine-readable CLI output must remain stable.
- Keep stdout machine-readable when `--format=json` is active.
- Send diagnostics and verbose logs to stderr.
- Do not import Playwright, canvas, capture, compositor, or encoder modules from the validation command path.
- Never put credentials, tokens, passwords, cookies, or secret environment values in Demo Plans or timeline artifacts.

## Product constraints

- The open-source CLI does not call an LLM or require an AI-provider API key.
- An external coding agent chooses the journey and authors the Demo Plan. Soredemo validates and executes it.
- Chromium is the only v0.1 browser.
- macOS is the initial development, golden-frame, and release authority, but source must remain platform-agnostic.
- v0.1 has exactly six browser actions: `goto`, `wait`, `moveTo`, `click`, `type`, and `scrollTo`.
- Camera movement exists only in post-production. Scrolling remains real browser scrolling.
- CDP frame timestamps are epoch-based and authoritative. Node receive time is diagnostic only.
- The capture spike must preserve a 1440×900 CSS viewport and prove native 2880×1800 JPEG output.
- Use only `ghost-cursor`'s exported `path()` function. Soredemo owns Playwright dispatch and timing.
- Do not implement frame resampling, canvas composition, camera movement, or FFmpeg encoding before their planned phases.

The accepted architectural decisions are in `docs/adr/`. Do not relitigate them during implementation.
