# Soredemo Studio design system

Dark, professional macOS editor in the Screen Studio quality class. The
distinctive visual language is **structured intent and evidence**: the UI makes
plans, execution, and proof visible — not just pixels. Dark theme only for now
(light theme is future work). Codifies the tokens implemented in
`studio/ui/src/styles/tokens.css`; see [ADR 0012](adr/0012-react-studio-ui.md).

The palette derives from the `soredemo-vector-brand` assets (deep navy `#0B0E13`
surfaces, off-white `#F4F4F7` text, the cursor-spark blue `#6EA8D6` accent, the
red `#F0443E` attention mark) reconciled with the Day-18 brief. **Deviation from
the brief:** the brief proposed a teal `#33C6B8` accent chosen to differ from
Screen Studio; the actual brand accent is the cursor-spark blue `#6EA8D6`, which
is used instead so the UI matches the logo and identity. The brand blue is the
single restrained accent that marks the *current* thing.

## Tokens

### Surfaces (layered dark)
| Token | Value | Use |
| --- | --- | --- |
| `--bg-app` | `#0B0E13` | app background, stage |
| `--bg-panel` | `#14171D` | rails, title/status bars |
| `--bg-raised` | `#1B1F27` | controls, badges |
| `--bg-overlay` | `#232833` | hover, popovers |
| `--border` | `#2A2F3A` | hairline borders |
| `--border-strong` | `#3A4150` | control borders |

### Text
| Token | Value | Use |
| --- | --- | --- |
| `--text-primary` | `#F4F4F7` | primary text |
| `--text-secondary` | `#9BA1AB` | labels, secondary |
| `--text-muted` | `#6A6F7A` | hints, tickers |

### Accent (single, restrained) — marks the current thing
| Token | Value |
| --- | --- |
| `--accent` | `#6EA8D6` (brand cursor-spark blue) |
| `--accent-hover` / `--accent-active` | `#8CBDE5` / `#5793C2` |
| `--accent-soft` | `rgba(110,168,214,0.14)` (active step wash) |
| `--attention` | `#F0443E` (brand red; sparing) |

### Semantic evidence colors (the proof language)
| Token | Value | Meaning |
| --- | --- | --- |
| `--verified` | `#3FB950` | verified-live / encoded-verified |
| `--recorded` | `#D29922` | future recorded-* levels |
| `--info` | `#58A6FF` | imported / authored |
| `--danger` | `#F0443E` | failures, TARGET_NOT_FOUND |

### Type
- UI: system stack (`-apple-system`/SF Pro). Mono: `ui-monospace`/SF Mono for
  **hashes, event codes, plan JSON, timestamps, and all evidence values**.
- Scale: 11 / 12 / 13 (base) / 15 / 20 px. Weights: 400 / 500 / 600 only.

### Shape, space, motion
- 4px spacing grid (`--s1`…`--s8`). Radii: 6px controls, 10px panels.
- Subtle shadows on raised layers only. Focus ring: accent, 2px.
- Motion: 120–180ms ease-out; `prefers-reduced-motion` disables it; no
  decorative animation.

## Layout — the three-zone studio

```
┌────────────┬───────────────────────────┬───────────────┐
│ Left rail  │ Center stage              │ Right rail    │
│ Authoring  │ live preview during runs; │ Demo plan     │
│ (AI chat,  │ MP4 result after;         │ steps + per-  │
│ plan       │ empty state before        │ action status │
│ paste/edit,│                           │ + evidence    │
│ approve)   │                           │ (badges,hash) │
├────────────┴───────────────────────────┴───────────────┤
│ Status bar: run-state machine, event ticker, project    │
└─────────────────────────────────────────────────────────┘
```

Center stage always dominant. Minimum window 1200×760 handled gracefully.

## Signature element — the plan rail

The right rail renders the approved plan as a vertical checklist. Each
`ActionStep` carries live state (pending / resolving / active / completed /
failed); the active step is accent-marked and auto-scrolled; completed
cursor-bearing steps show inline evidence (`cursor ✓`, `target px ✓`); the exact
plan hash is shown in mono with the approval state (approved / awaiting /
invalidated). Execution reads like a mission checklist verified in real time —
the product's identity on screen.

## Component inventory
`Glyph` (brand そ mark), `ChatPanel` (authoring: agent + manual plan + approve/
run), `PreviewStage` (empty / live sample / final MP4), `PlanRail`
(hash + approval + steps + run evidence + artifacts), `ActionStep`, `ProofBadge`
(verified/danger/info/neutral), `StatusBar` (run-state dot + event ticker +
project + version).

## Copy rules
Sentence case. Buttons say what happens ("Approve plan", "Start run", "Stop
run"). Errors name the stable code (e.g. `TARGET_NOT_FOUND`) plus a
plain-language line. Empty states invite the next action ("Approve a plan and
start a run…"). Never marketing language inside the tool.

## Do / don't
- **Do** keep mono for every evidence value; keep the accent for the single
  current thing; keep the plan rail as the focal identity.
- **Don't** introduce a second accent hue, fetch remote fonts/resources, add
  decorative motion, or use color as the only signal (pair with text/label).
