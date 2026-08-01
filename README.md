# Soredemo

**Every team ships. Almost nobody sees what they shipped.**

Soredemo turns each release into a published demo — detected from GitHub, recorded once, derived into
video and launch copy, reviewed by a person, and posted.

macOS 27 · Swift 6.4 · Apple Silicon · local by default

> **Status: pre-implementation.** Phase 0 validates the core hypothesis before any app code is
> written. See [`ROADMAP.md`](ROADMAP.md).

---

## Start here

**Coding agent:** read [`AGENTS.md`](AGENTS.md) first — it governs everything — then
[`KICKOFF.md`](KICKOFF.md).

**Person returning to this repo:** [`docs/PRODUCT.md`](docs/PRODUCT.md) for why, then
[`ROADMAP.md`](ROADMAP.md) for what is next.

---

## The documents

Six documents. That is all of it.

| Document | What it settles |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | **Working agreement.** Method, rules, the publishing rule |
| [`ROADMAP.md`](ROADMAP.md) | **The only ordered work list.** Take the first unblocked row |
| [`docs/PRODUCT.md`](docs/PRODUCT.md) | Positioning, the loop, and what is deliberately not built |
| [`docs/FEATURES.md`](docs/FEATURES.md) | **Every feature and the Apple framework behind it.** Four pillars: record, edit, launch video, CLI + agent |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Eight binding decisions (D1–D8) and the module map |
| [`docs/TOOLCHAIN.md`](docs/TOOLCHAIN.md) | Xcode 27 and macOS 27 setup |
| [`KICKOFF.md`](KICKOFF.md) | Copy-paste prompts for Claude Code + a skill chain |

---

## The rules that matter most

**The completion rule.** A row is not complete while the behaviour its name claims is not observable in
the product. A pure function with no caller does not satisfy a row that claims a product behaviour.

**The producer-value rule.** An authored override always wins over a derived value and is never
silently replaced. Test it by supplying a value the producer could not have derived.

**The publishing rule.** Soredemo never posts anything without explicit, per-post human approval. No
auto-publish, no "approve all", no CI bypass.

**Native Liquid Glass only.** App chrome is 100% standard SwiftUI. Never `.glassEffect()`, never
`NSGlassEffectView`. Content surfaces are deliberately opaque.

---

## Layout

```
Soredemo/
├── soredemo-main/        ← this repo
│   ├── AGENTS.md  ROADMAP.md  KICKOFF.md  README.md
│   └── docs/
│       └── PRODUCT.md  FEATURES.md  ARCHITECTURE.md  TOOLCHAIN.md
├── soredemo-web/         brand kit, design research
└── opensource/           comparable projects — read for ideas, not for code
```

Brand assets: `../soredemo-web/soredemo-brand-kit/` — SVG, PNG, favicon, `tokens/colors.json`.
