# Validator1 public status — later upgrades Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (recommended for this plan — two repos + apply gates) or superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the previewed static trust card (health pill, hover charts, glossary, 30s poll) to the live URL, then make the 30d/All charts honest, then make the publisher a true 5-minute Cloud Run Job, then ship the D2 public-data health report.

**Architecture:** The page stays **static HTML + `status-logic.js`** on `gs://csyn-www-validator1-toml/` behind `csyn-www-url-map` host `validator1.cloudsyndicate.io`. Live tiles/charts read `/status.json` + `/history.json` written by `tools/publish_public_status.py`. OpenTofu in `cloud-syndicate-platform/shared/www` owns the HTML/JS/brand objects. The publisher (GHA today; Cloud Run Job already scaffolded and digest-gated) owns the JSON. D2 is a second static HTML object on the same bucket, client-side public probes only — never the validator VPC or admin RPC.

**Tech Stack:** Static HTML/vanilla JS; Python 3.12 publisher; OpenTofu 1.12.0; GCS + existing global HTTPS LB; optional Cloud Run Job + Cloud Scheduler (`us-central1`); GitHub Actions WIF for the current publisher.

**Spec:** This plan is the sequel to `docs/superpowers/plans/2026-08-09-validator-trust-and-public-ai-ops.md` (A1+D2). Previewed design source: `docs/public/validator1/index.html` + `status-logic.js` on branch `feat/validator1-status-strip` (commit `b0c7542` and any follow-ups). Original visitor prompt (2026-08-16) asked for the strip + charts; React, network-average, and Chart.js CDN were declined.

## Global Constraints

- Stay static HTML. **No React / Next / SPA rewrite.**
- OpenTofu only for prod object and infra changes. **No `gcloud storage cp` of managed HTML/TOML/brand.**
- `billing_project = "csyn-platform"` + `user_project_override = true`; `tofu` not `terraform`; `TF_CLI_CONFIG_FILE` → `.ci/tofu-mirror.tofurc`.
- Ask Pete before any **push**, **`apply.yml` dispatch**, or **www apply**.
- Two writers must never run: do **not** set `public_status_image_digest` while `.github/workflows/publish-validator1-status.yml` is enabled.
- CLAIM1: no frozen live agreement / peer / sample-age numbers in HTML or comments. Captions read `history.window_days`.
- Copy walls: no “FedRAMP authorized”; UNL Active ≠ default-UNL membership; Agreement is `data.xrpl.org`, not localhost.
- FOLDER1: `cloud-syndicate-platform` edits go in a **new worktree off `origin/main`**. Do not `git switch` the shared clone. Do not reuse `cloud-syndicate-platform-wt-validator1-trust` (stale `feat/www-validator1-trust-card`).
- Dual-gate T2 before merge of any task that ships to the live URL or changes the publisher.
- Stop after any task — each one is independently shippable.

## File map

| File | Role |
|------|------|
| `docs/public/validator1/index.html` | Design source for the live landing |
| `docs/public/validator1/status-logic.js` | Health / Δ / Y-domain; must ship as its own GCS object |
| `docs/public/validator1/status-logic.test.js` | `node --test` for the helpers |
| `docs/public/health/index.html` | D2 design source (already exists) |
| `tools/publish_public_status.py` | Builds + uploads `status.json` / `history.json` |
| `tools/test_publish_public_status.py` | Publisher unit tests (create in Task 2) |
| `tools/Dockerfile.public-status` + `tools/cloudbuild.public-status.yaml` | Cloud Run image (Task 3) |
| `.github/workflows/publish-validator1-status.yml` | Current 5m GHA publisher — disable in Task 3 |
| `ledger-workloads/validator-prod/public-status-publisher.tf` | Digest-gated Job + Scheduler |
| `ledger-workloads/validator-prod/variables.tf` `public_status_image_digest` | Empty today; pin in Task 3 |
| `cloud-syndicate-platform/shared/www/validator1.tf` | `validator1_index` + brand for_each; add `validator1_status_logic` (Task 1) and `validator1_health` (Task 4) |
| `cloud-syndicate-platform/shared/www/validator1-content/` | Live object sources |

---

### Task 1: Ship the previewed page to the live URL

**Files:**
- Modify (this repo, already on `feat/validator1-status-strip`): `docs/public/validator1/index.html` (caption reads `window_days`)
- Create (platform worktree): `shared/www/validator1-content/status-logic.js`
- Modify (platform worktree): `shared/www/validator1-content/index.html`, `shared/www/validator1.tf`

**Interfaces:**
- Consumes: previewed `index.html` + `status-logic.js` from this repo
- Produces: GCS objects `index.html` and `status-logic.js` on `csyn-www-validator1-toml`; live `/` still rewritten to `/index.html`

- [ ] **Step 1: Make the retained-window caption derive from JSON**

In `docs/public/validator1/index.html`, store `state.windowDays` from `history.window_days` (fallback 7) and build the caption from that. Do not hardcode `"7-day"`.

```javascript
state.windowDays = (history && history.window_days) || state.windowDays || 7;
// in redraw():
var retain = (state.range === "30d" || state.range === "all")
  ? (" · " + state.windowDays + "-day retained window")
  : "";
```

Same change in the glossary Sample-age sentence: keep it qualitative (“the retained window advertised by history.json”), or leave the current “about seven days” only until Task 2.

- [ ] **Step 2: Run helper tests (must stay green)**

```bash
node --test docs/public/validator1/status-logic.test.js
```

Expected: 10 pass, 0 fail.

- [ ] **Step 3: Commit the caption change in this repo**

```bash
git add docs/public/validator1/index.html
git commit -m "fix(validator1): read retained window from history.window_days"
```

- [ ] **Step 4: Create a platform worktree off origin/main**

```bash
git -C /Users/petermorse/pete-ai/claude/cs/cloud-syndicate-platform fetch origin --no-prune
git -C /Users/petermorse/pete-ai/claude/cs/cloud-syndicate-platform worktree add \
  -b feat/www-validator1-status-strip \
  /Users/petermorse/pete-ai/claude/cs/cloud-syndicate-platform-wt-validator1-status \
  origin/main
```

Do not `git switch` the shared clone. Do not reuse `cloud-syndicate-platform-wt-validator1-trust`.

- [ ] **Step 5: Copy design source into www content**

```bash
SRC=/Users/petermorse/pete-ai/claude/cs/csyn-consensus-prod-wt-validator1-status/docs/public/validator1
DST=/Users/petermorse/pete-ai/claude/cs/cloud-syndicate-platform-wt-validator1-status/shared/www/validator1-content
cp "$SRC/index.html" "$DST/index.html"
cp "$SRC/status-logic.js" "$DST/status-logic.js"
# Do not copy status-logic.test.js — not a public object.
```

- [ ] **Step 6: Add the JS object in `validator1.tf` next to `validator1_index`**

```hcl
resource "google_storage_bucket_object" "validator1_status_logic" {
  name          = "status-logic.js"
  bucket        = google_storage_bucket.validator1.name
  source        = "${path.module}/validator1-content/status-logic.js"
  content_type  = "application/javascript; charset=utf-8"
  cache_control = "public, max-age=60, must-revalidate"
}
```

If `index.html` is applied without this object, the live page’s `<script src="status-logic.js">` 404s and the health pill stays “Checking”. Apply both in the same apply.

- [ ] **Step 7: Platform plan (read-only; no apply)**

```bash
export TF_CLI_CONFIG_FILE="$PWD/.ci/tofu-mirror.tofurc"
tofu -chdir=shared/www init -input=false
tofu -chdir=shared/www plan -input=false
```

Expected: add `google_storage_bucket_object.validator1_status_logic`; update `validator1_index` (content hash). **No** change to `validator1_toml`. If toml is in the plan, STOP.

- [ ] **Step 8: Commit + PR in platform; dual-gate; ask Pete before push/apply**

```bash
git add shared/www/validator1.tf shared/www/validator1-content/index.html shared/www/validator1-content/status-logic.js
git commit -m "feat(www): validator1 health-strip landing + status-logic.js"
```

After merge + Pete-approved apply, re-run (do not freeze the codes):

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://validator1.cloudsyndicate.io/
curl -sS -o /dev/null -w "%{http_code}\n" https://validator1.cloudsyndicate.io/status-logic.js
curl -sS -o /dev/null -w "%{http_code}\n" https://validator1.cloudsyndicate.io/.well-known/xrp-ledger.toml
```

Expected: three 200s. Browser: health pill not stuck on Checking; charts hover; TOML body still contains `nHUQEd51hNxF3vdVHJKewxZUzXqiP78agDL2bVSiA7Ja4dRFZUGq`.

---

### Task 2: Honest 30-day history

**Files:**
- Create: `tools/test_publish_public_status.py`
- Modify: `tools/publish_public_status.py` (`HISTORY_DAYS`, `AGREE_SNAP_MAX`, history `page_size`)
- Modify: `docs/public/validator1/index.html` only if Task 1 caption work is not already on `main`

**Interfaces:**
- Consumes: `merge_agreement_snaps(prior, now=, pct=)` existing signature
- Produces: `history.window_days == 30`; peer/proposing series ≈ 720 hourly points; agreement snapshots retained 30 days up to `AGREE_SNAP_MAX`

- [ ] **Step 1: Write the failing publisher tests**

```python
# tools/test_publish_public_status.py
from datetime import datetime, timedelta, timezone
from publish_public_status import HISTORY_DAYS, AGREE_SNAP_MAX, merge_agreement_snaps

def test_history_days_is_thirty():
    assert HISTORY_DAYS == 30

def test_snap_cap_covers_thirty_days_at_five_min():
    # 30d * 24h * 12 publishes/hour = 8640
    assert AGREE_SNAP_MAX >= 8640

def test_merge_drops_points_older_than_window():
    now = datetime(2026, 8, 16, 12, 0, tzinfo=timezone.utc)
    old = {"t": (now - timedelta(days=31)).strftime("%Y-%m-%dT%H:%M:%SZ"), "v": 99.0}
    keep = {"t": (now - timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ"), "v": 99.5}
    out = merge_agreement_snaps([old, keep], now=now, pct=100.0)
    assert all((p["t"] or "") >= (now - timedelta(days=HISTORY_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ") for p in out)
    assert out[-1]["v"] == 100.0
```

- [ ] **Step 2: Run tests — expect fail on `HISTORY_DAYS == 30`**

```bash
cd tools && python3 -m pytest test_publish_public_status.py -v
```

Expected: FAIL `assert 7 == 30` (or pytest not installed → `python3 -m unittest` with the same asserts).

- [ ] **Step 3: Minimal publisher change**

In `tools/publish_public_status.py`:

```python
HISTORY_DAYS = 30
AGREE_SNAP_MAX = 9000
```

In `fetch_hist` / `monitoring_get` for history, set `page_size=800` (720 hourly points in 30d; existing pager still required).

- [ ] **Step 4: Re-run tests — expect pass**

```bash
cd tools && python3 -m pytest test_publish_public_status.py -v
```

Expected: PASS.

- [ ] **Step 5: Local publisher dry-run (no upload unless Pete asks)**

```bash
python3 tools/publish_public_status.py --local-dir /tmp/csyn-v1-status
python3 -c "import json; h=json.load(open('/tmp/csyn-v1-status/history.json')); print(h['window_days'], h['point_counts'])"
```

Expected: `window_days` 30; `peer_count` well above 168 once Monitoring returns the longer window. First publish after deploy still has only the snaps already in GCS plus one new point — the 30d snap series fills over subsequent publishes. Hourly peer/proposing should jump immediately.

- [ ] **Step 6: Commit**

```bash
git add tools/publish_public_status.py tools/test_publish_public_status.py
git commit -m "feat(status): retain 30 days of public history"
```

Merges to `main` pick up on the next GHA publish. No validator-prod apply required.

---

### Task 3: Cloud Run Job cutover (true 5-minute publisher)

**Files:**
- Modify: `.github/workflows/publish-validator1-status.yml` (disable schedule)
- Modify: `ledger-workloads/validator-prod/variables.tf` or the apply-time `-var` only — **prefer a committed empty default and a Pete-supplied apply var**, not a digest committed before the image exists
- Already present: `ledger-workloads/validator-prod/public-status-publisher.tf`, `tools/Dockerfile.public-status`, `tools/cloudbuild.public-status.yaml`

**Interfaces:**
- Consumes: image `us-south1-docker.pkg.dev/csyn-ldg-host-dev/csyn-ldg-images/validator1-status-publisher@sha256:…`
- Produces: one writer — Cloud Run Job `validator1-public-status` + Scheduler `validator1-public-status-5m` in `us-central1`

- [ ] **Step 1: Confirm GHA is the only writer (before touching anything)**

```bash
gh run list --workflow=publish-validator1-status.yml --limit 5
gcloud run jobs list --project=csyn-ldg-validator-prod --region=us-south1 \
  --filter='name:validator1-public-status' --format='value(name)'
```

Expected: GHA runs present; Cloud Run Job name empty (digest still `""`).

- [ ] **Step 2: Build the image (does not start a second writer)**

```bash
gcloud builds submit --project=csyn-ldg-host-dev \
  --config=tools/cloudbuild.public-status.yaml \
  tools/
gcloud artifacts docker images describe \
  us-south1-docker.pkg.dev/csyn-ldg-host-dev/csyn-ldg-images/validator1-status-publisher:1.0.0 \
  --format='value(image_summary.digest)'
```

Record the `sha256:…` digest. Do not put it in `variables.tf` default yet.

- [ ] **Step 3: Disable GHA first (closes the race)**

Replace the `on.schedule` block with a comment that Task 3 moved the cadence to Cloud Scheduler. Keep `workflow_dispatch` temporarily so a manual publish is still possible during the gap.

```yaml
on:
  # schedule removed — Cloud Run Job + Scheduler owns */5 after digest apply
  workflow_dispatch:
```

Commit + merge this **before** the digest apply.

```bash
git add .github/workflows/publish-validator1-status.yml
git commit -m "chore(status): stop GHA cron before Cloud Run publisher cutover"
```

- [ ] **Step 4: Pete-approved apply of validator-prod with the digest**

```bash
# After Pete says apply — example only
export TF_CLI_CONFIG_FILE="$PWD/.ci/tofu-mirror.tofurc"
tofu -chdir=ledger-workloads/validator-prod plan \
  -var="public_status_image_digest=sha256:REPLACE" \
  -input=false
```

Expected: add Job + Scheduler + AR pull; **no** unrelated destroy. Then dispatch `apply.yml` the same way this repo always applies (Pete). Do not apply from a laptop against prod unless Pete directs it.

- [ ] **Step 5: Prove one writer, 5-minute cadence**

```bash
gcloud run jobs executions list --project=csyn-ldg-validator-prod \
  --region=us-south1 --job=validator1-public-status --limit=5
curl -sS "https://validator1.cloudsyndicate.io/status.json?_=$(date +%s)" \
  | python3 -c "import json,sys; s=json.load(sys.stdin); print(s['published_at'], s['metrics_fresh'])"
```

Expected: executions ~5 minutes apart; `published_at` advancing; `metrics_fresh` true. Then delete `workflow_dispatch` from the GHA file in a follow-up commit so the workflow is fully retired.

---

### Task 4: D2 public health report on the same host

**Files:**
- Modify (platform worktree off `origin/main`): `shared/www/validator1.tf`, `shared/www/validator1-content/health.html`
- Modify (this repo design source): `docs/public/health/index.html` (copy into `health.html`); `docs/public/validator1/index.html` (one nav link)

**Interfaces:**
- Consumes: existing D2 page at `docs/public/health/index.html` (client-side TOML/HTTP probes)
- Produces: `https://validator1.cloudsyndicate.io/health.html` — no GCLB rewrite, no Cloud Run

- [ ] **Step 1: Copy D2 to a root object name (avoids a `/health/` rewrite)**

```bash
cp docs/public/health/index.html \
  /Users/petermorse/pete-ai/claude/cs/cloud-syndicate-platform-wt-…/shared/www/validator1-content/health.html
```

Add a “Health report” ghost button on the trust card pointing at `/health.html`. Do not invent FedRAMP language. Keep D2’s hard wall: no Cloud Logging, no Secret Manager, no admin ports.

- [ ] **Step 2: TF object**

```hcl
resource "google_storage_bucket_object" "validator1_health" {
  name          = "health.html"
  bucket        = google_storage_bucket.validator1.name
  source        = "${path.module}/validator1-content/health.html"
  content_type  = "text/html; charset=utf-8"
  cache_control = "public, max-age=300, must-revalidate"
}
```

No `gclb.tf` change. `full_path_match = "/"` already rewrites only `/`.

- [ ] **Step 3: Plan, then Pete-approved apply**

```bash
tofu -chdir=shared/www plan -input=false
```

Expected: add `validator1_health` only (plus the index link hash if Task 1 already shipped). TOML unchanged.

- [ ] **Step 4: Verify**

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://validator1.cloudsyndicate.io/health.html
curl -sS -o /dev/null -w "%{http_code}\n" https://validator1.cloudsyndicate.io/.well-known/xrp-ledger.toml
```

Expected: 200 / 200. Open `/health.html`, click Generate, confirm TOML + root HTTP rows populate from public fetches.

---

## Out of scope (do not grow this plan)

- React / Next rewrite
- Chart.js / ECharts CDN (or vendoring) — canvas hover is enough
- Network-average overlay — `data.xrpl.org` does not publish that series
- Option C validator directory
- Sidecar “last proposal” gauge (no metric today; do not invent Sample age as proposal age)
- Changing the live TOML key or domain

## Suggested order

1 → 2 can overlap after 1 is applied (publisher change is this repo only).  
3 only after 2 is on `main` (so the Job image includes 30-day history).  
4 anytime after 1 (independent surface).

## Self-review

- Spec coverage: live ship, honest 30d, 5m publisher, D2 — each has a task. React explicitly excluded.
- No TBD/placeholder steps. Exact files, commands, and HCL/JS/Python included.
- Names consistent: `validator1_status_logic`, `validator1_health`, `HISTORY_DAYS`, `public_status_image_digest`.
