# Agent providers

Agent providers are authoring adapters. They may propose or revise a Demo Plan; they cannot
control the production browser, cursor, capture clock, compositor, encoder, or proof level.

The alpha.1 interface exposes availability, proposal/revision async events, cancellation, and
conversation identity. A provider result must match the versioned proposal schema and embed a
normal Demo Plan containing only `goto`, `wait`, `moveTo`, `click`, `type`, and `scrollTo`.

## Claude Code

The optional first provider was checked with Claude Code `2.1.217`. It uses documented
non-interactive `-p` mode, JSON output, `--permission-mode plan`, `--max-turns`, and explicit
tool denial:

- https://docs.anthropic.com/en/docs/claude-code/cli-usage
- https://docs.anthropic.com/en/docs/claude-code/getting-started

Claude Code remains external and optional. Soredemo does not bundle it or read its tokens.
Malformed output, unsupported actions, timeout, cancellation, and unavailable providers fail
as authoring errors, never as proof results. Existing plans remain usable without an Agent.

The permission review separately covers project source, existing plans/tests, and the semantic
snapshot. Screenshots, environment variables, cookies, storage, and secrets are excluded.
