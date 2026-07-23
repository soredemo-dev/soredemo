# Day 15 — Studio vertical slice

Alpha.1 connects authoring, approval, execution, evidence, and output without adding a second
renderer:

```text
AI proposes → user approves exact hash → production runner executes
→ proof engine verifies → production compositor and encoder publish
```

Studio is static web assets plus a Node loopback server. It shares `RunCoordinator` with the
CLI. Preview comes from production screencast frames only after acknowledgement, is sampled
at 2 fps, and is never authoritative.

The Agent bridge is external, optional, bounded, and read-only. Soredemo collects only
approved source excerpts and semantic context. Plans are validated with the existing schema,
written atomically after approval, and invalidated by edits.

Pause and takeover were deferred: pause needs explicit media-time semantics at safe action
boundaries, and takeover requires a new proof-level and input-authority model. Manual web
recording remains a future capture adapter that must produce reviewable Demo IR and feed the
existing compositor. Mobile remains a later adapter/device-compositor problem.
