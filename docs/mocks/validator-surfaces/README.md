# EverForge public surfaces — design mocks (A + C + D)

Institutional suite with light marketing. **Not production.** Not third-party clones.

## Open

```bash
cd /Users/petermorse/pete-ai/claude/cs/csyn-consensus-prod/docs/mocks/validator-surfaces
python3 -m http.server 8765 --bind 127.0.0.1
# http://127.0.0.1:8765/options-board.html  ← pick A + D variants
# http://127.0.0.1:8765/                     ← full suite index
```

| File | Role |
|------|------|
| **`options-board.html`** | **Pick A1/A2/A3 and D1/D2/D3** |
| `option-a-trust-card.html` | **A1** institutional + light marketing (recommended ship) |
| `option-a2-minimal.html` | **A2** CarbonVibe-shaped minimal |
| `option-a3-status-lite.html` | **A3** trust + status-lite (needs public feeds) |
| `option-d-ai-ops.html` | **D1** interactive agent demo |
| `option-d2-report.html` | **D2** audit-style report (recommended primary D) |
| `option-d3-embed.html` | **D3** compact embed card |
| `option-c-directory.html` | **C** deferred |
| `index.html` | Full suite comparison |
| `gates/` | Gate notes |
| Plan | `docs/superpowers/plans/2026-08-09-validator-trust-and-public-ai-ops.md` |

## Live hosting (A deploy target)

Verified 2026-08-09: `csyn-www-prod` · `gs://csyn-www-validator1-toml/` · LB host rule `validator1.cloudsyndicate.io`. Only TOML object today; root 403.

## Product path

1. **A** first — static trust card on the same host as TOML (closes human 403).
2. **C** — curated directory / SEO / authority.
3. **D** — public-data AI demo (Cloud Run later); hard walls.

## Gate honesty

Headless Fable 5 did not complete (auth / empty stdout). Interim adversarial findings were applied in-suite. Re-run Fable 5 from an interactive Claude session with `gates/fable5-brief.md` before calling dual-gate MERGE.

## Brand

Navy/gold tokens aligned with cloudsyndicate.io (`#05090f`, `#1f4286`, `#c9a86a`, `#F3FAFC`). IBM Plex Sans/Mono via Google Fonts.
