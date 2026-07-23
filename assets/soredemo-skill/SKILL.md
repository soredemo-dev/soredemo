---
name: soredemo
description: Author and verify Soredemo Demo Plans for already-running web applications.
---

# Soredemo authoring

Create reviewable YAML Demo Plans; never execute an unapproved proposal.

- Use only `goto`, `wait`, `moveTo`, `click`, `type`, and `scrollTo`.
- Prefer role plus accessible name, then label, configured test ID, exact visible text, and only then an explicitly reviewed CSS selector.
- Every target must resolve to exactly one element. Never choose the first ambiguous match, heal selectors, or invent inaccessible elements.
- Treat the application as already running. Do not install packages, start servers, access credentials, or include secrets.
- Validate the plan before rendering.
- Distinguish authoring proposals from verified execution. Only Soredemo's runner and proof engine may report `verified-live` or `encoded-verified`.
- After completion, inspect the proof summary as well as the MP4.
