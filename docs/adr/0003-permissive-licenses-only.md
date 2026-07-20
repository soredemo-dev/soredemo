# ADR 0003: Permissive runtime licenses only

- Status: Accepted
- Date: 2026-07-21

## Context

Soredemo is MIT licensed and must not silently impose source-available, proprietary, dual-license, or headcount-conditioned obligations on local users.

## Decision

Ship only permissively licensed runtime dependencies such as MIT, Apache-2.0, ISC, or BSD. Review every proposed dependency and keep the runtime graph small. Remotion is banned from the dependency tree.

If a hand-built canvas compositor is proven infeasible, Revideo and Motion Canvas may be reevaluated before adoption. Neither is an automatic fallback.

## Consequences

Dependency license and supply-chain review is part of release work. Soredemo independently implements its runtime and copies no Remotion code, files, snippets, internal APIs, or implementation details.
