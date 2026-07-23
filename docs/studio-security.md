# Studio security

Studio binds to `127.0.0.1` by default. Non-loopback binding prints a prominent warning and is
not a supported remote deployment.

- A cryptographically random per-process token is held only in memory.
- The browser receives it only as an HttpOnly, SameSite=Strict cookie.
- Mutation requests require the cookie and the exact Studio origin.
- CORS is not enabled; CSP and anti-framing headers are set.
- Request paths must be project-relative and cannot escape through `..`, encoded traversal,
  absolute paths, or symlinks.
- Only explicitly registered run artifacts can be served. There is no filesystem browser,
  shell endpoint, environment endpoint, credential endpoint, or telemetry.
- `.soredemo/studio.json` contains only local connection metadata and a PID, never the token.

Preview pixels and proofs can contain private application information. No image is uploaded.
Agent screenshots are excluded. Source and semantic snapshot access are separate explicit
permissions. `.env`, cookies, storage, environment variables, Git credentials, and browser
authentication state are excluded.

Claude Code receives bounded approved context through stdin, never command-line arguments. It
runs in documented plan mode with shell, file, web, and notebook tools disallowed. Soredemo
performs approved bounded source reads itself, excluding `.env` and build/cache directories.
