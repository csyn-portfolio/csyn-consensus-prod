# Validator trust card (A) + public health surface (D) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:executing-plans` or `subagent-driven-development` after Pete picks mock variants.

**Goal:** Ship a professional public landing on `validator1.cloudsyndicate.io` (Option A), then a public-data-only health surface (Option D). Defer Option C.

**Architecture:** Domain already terminates on Cloud Load Balancing in **`csyn-www-prod`**, host rule → backend bucket → **`gs://csyn-www-validator1-toml/`**. A is a static object upload (+ optional URL map path for `/`). D is a separate app (Cloud Run later) using only public APIs — never the validator VPC/admin plane.

**Tech Stack:** GCS + existing global HTTPS LB (`csyn-www-url-map`); static HTML for A; Cloud Run + public HTTP clients for D (phase 2).

## Global Constraints

- OpenTofu only for infra changes in CS repos; A may be **object-only** if URL map already correct — confirm before TF.
- Project for domain host: **`csyn-www-prod`** (not `csyn-ldg-validator-prod`).
- Validator project stays private; no admin RPC, no private metrics on A/D.
- No “FedRAMP authorized” language; design baseline wording only as on cloudsyndicate.io.
- Ask Pete before push / apply / prod object upload that is irreversible-ish for marketing DNS.
- CLAIM1: no frozen live agreement numbers in static A page.

## Hosting facts (verified 2026-08-09)

| Item | Value |
|------|--------|
| DNS | `validator1.cloudsyndicate.io` → `8.232.218.28` (Google LB) |
| Project | `csyn-www-prod` |
| URL map | `csyn-www-url-map` host `validator1.cloudsyndicate.io` → pathMatcher `validator1` |
| Backend bucket | `csyn-www-validator1-backend` → `csyn-www-validator1-toml` |
| Objects today | Only `.well-known/xrp-ledger.toml` |
| `GET /` | HTTP 403 AccessDenied (GCS) |
| `GET /index.html` | HTTP 404 (object missing) |
| TOML | HTTP 200, CORS `*`, custom headers HSTS / nosniff / noindex |

**A ship mechanic:** upload chosen mock as `index.html` to the bucket with `Content-Type: text/html`. If `GET /` still 403/404 after upload, add path rewrite `/` → `/index.html` on pathMatcher `validator1` (TF home likely **csyn website / www-prod repo**, not this consensus-prod root — locate before editing).

---

### Task 1: Pete picks mock variants

**Files:** `docs/mocks/validator-surfaces/options-board.html`

- [ ] **Step 1:** Open http://127.0.0.1:8765/options-board.html
- [ ] **Step 2:** Choose A1 / A2 / A3 and D1 / D2 / D3 (recommended: **A1 + D2**, D1 later)
- [ ] **Step 3:** Record choice in TASKS.md one-liner

---

### Task 2: Finalize A HTML for production

**Files:**
- Create: `docs/public/validator1/index.html` (ship artifact, no mock banner)
- Source from chosen A mock under `docs/mocks/validator-surfaces/`

- [ ] **Step 1:** Copy chosen A mock; strip mock banners and local nav to C/D if not yet public
- [ ] **Step 2:** Keep: master key, TOML link, explorers, security contact, EverForge one-liner, posture bullets
- [ ] **Step 3:** Local check: open file in browser; no console deps required offline except fonts (acceptable)
- [ ] **Step 4:** Commit on branch (no push without ask)

---

### Task 3: Deploy A to `gs://csyn-www-validator1-toml/`

**Requires:** Pete explicit approve for prod object write

```bash
# After approval — example only
gcloud storage cp docs/public/validator1/index.html \
  gs://csyn-www-validator1-toml/index.html \
  --content-type=text/html \
  --cache-control="public, max-age=300"
```

- [ ] **Step 1:** Pete approves prod upload
- [ ] **Step 2:** Upload `index.html`
- [ ] **Step 3:** `curl -sS -o /dev/null -w "%{http_code}\n" https://validator1.cloudsyndicate.io/index.html` → expect 200
- [ ] **Step 4:** `curl -sS -o /dev/null -w "%{http_code}\n" https://validator1.cloudsyndicate.io/` → expect 200; if not, Task 4
- [ ] **Step 5:** Confirm TOML still 200 and unchanged

---

### Task 4: URL map `/` → `index.html` if needed

**Likely home:** website / `csyn-www-prod` Terraform (not validator-prod). Do not invent TF in this repo without owner.

- [ ] **Step 1:** Locate TF for `csyn-www-url-map` pathMatcher `validator1`
- [ ] **Step 2:** Add rewrite or default object mapping so `/` serves `index.html`
- [ ] **Step 3:** Plan + apply per cs-terraform-overlay / flight-control (Pete apply if bootstrap-class)
- [ ] **Step 4:** Re-curl `/` → 200

---

### Task 5: D public health surface (after A live)

**Pick D2 first (automated report) unless sales needs D1 chat.**

- [ ] **Step 1:** Spec sources: XRPScan registry, TOML GET, root GET, explorers only
- [ ] **Step 2:** Implement report generator (Go or TS) with hard walls unit tests
- [ ] **Step 3:** Planted positives: missing TOML, 403 root, bad domain → fail correctly
- [ ] **Step 4:** Host on Cloud Run in marketing/www project (not ledger validator VPC)
- [ ] **Step 5:** Optional host e.g. `health.cloudsyndicate.io` or path on www — separate change
- [ ] **Step 6:** Dual-gate (Claude builder / Grok review or reverse) before public link

---

### Task 6: Durable state

- [ ] Update `TASKS.md` with A live verify commands (not frozen status)
- [ ] Hybrid log entry if session ends
- [ ] Defer C explicitly in TASKS

---

## Out of scope

- Option C directory
- Tachyon live dashboard on validator1
- Private agreement / Cloud Logging on public pages
- Fable 5 re-run (optional; interactive Claude when free)

## Success criteria

1. `https://validator1.cloudsyndicate.io/` returns institutional HTML 200 without breaking TOML verification  
2. D (when built) never calls private GCP for the target validator  
3. Pete-selected mock variants match production A look
