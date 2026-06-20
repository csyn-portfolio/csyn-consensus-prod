# Validator Monitoring Sidecar + Out-of-Band UNL Delivery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the egress-blocked public-API poller with a zero-egress on-VM sidecar that reads the validator's own admin RPC, and deliver fresh UNLs to the node out-of-band — both while preserving the regulated `ledger/prod` egress deny-floor unchanged.

**Architecture:** The validator project (`csyn-ldg-validator-prod`) has a VPC-wide egress deny-floor; only XRPL P2P and the Google restricted VIP are allowed. Two needs collided with that posture: (1) amendment/agreement **monitoring** (built as a Cloud Run job hitting `validations.xrpl.org` / `api.xrpscan.com` — fails, no internet), and (2) **UNL refresh** (statically pinned, `[validator_list_sites]` absent — a time-bomb: cached list expires **2026-Jul-24**). Decision (Pete, 2026-06-20, after networking + cs-ledger:observability + Grok consults): **keep the deny-floor.** WS1 moves monitoring onto an on-VM sidecar reading `localhost:5005` (zero egress, the cs-ledger canon baseline). WS2 delivers publisher-signed UNLs across the perimeter as *data* (not a new egress hole) and points `[validator_list_sites]` at a local/internal source — the node verifies the publisher signature itself, so the transport need not be trusted.

**Tech Stack:** Go 1.25 (sidecar + fetcher, reusing the existing poller module), OpenTofu 1.12.0, GCP Compute Engine (COS) / Cloud Monitoring / Artifact Registry / GCS or Secret Manager, GitHub Actions (image build in sibling repo).

## Global Constraints

- **OpenTofu only, pinned 1.12.0.** Use `tofu`, never `terraform`. `export TF_CLI_CONFIG_FILE="$PWD/.ci/tofu-mirror.tofurc"` for provider installs.
- **No direct push to `main`; all changes via PR.** Ask before any push, `apply.yml` dispatch, or merge-to-main. `tofu plan` and reads are fine.
- **CI apply identity is always `ledger-apply@csyn-platform.iam.gserviceaccount.com`** (no SA ternary).
- **`billing_project = "csyn-platform"` + `user_project_override = true`** in every provider block; any API new to the estate must ALSO be enabled on quota project `csyn-platform`.
- **Cross-repo layout:** Go code + image builds live in sibling `csyn-consensus-infra` (`docker/`, `build-poller-image.yml`); the VM-deploy Terraform lives in THIS repo (`ledger-workloads/validator-prod/`). Modules are git-sourced by tag from the sibling.
- **First-of-kind GCP resource → `gcp-arch-expert:gcp-ask` specialist pre-consult before authoring.**
- **Regulated prod signing node:** any command that runs *inside* the VM needs explicit, named approval. Validator config reloads use the clock-safe recreate (snapshot → drain/announce → recreate), never `docker rm -f`. Metadata push ≠ live — recreate the container and verify with `server_info`.
- **Deadline:** WS2 must be live before **2026-Jul-24 10:41 UTC** (current cached UNL `expiration`).

---

## Workstream 1 — On-VM Monitoring Sidecar (READY)

**Status:** plan-ready. Independent of WS2. Fixes the currently-broken monitoring and removes the dead Cloud Run job/scheduler.

**Design decisions resolved:**
- The sidecar is a refactor of the existing `docker/poller/main.go`: keep `extractAmendments`, `amendmentStatus`, the metric consts, `writeSeries`, the monitored-resource shape, and the heartbeat-last pattern. **Replace** `fetchAmendments` (→ xrpscan) and `fetchAgreement` (→ validations.xrpl.org) with calls to `localhost:5005` admin RPC (`feature`, `server_info`).
- **Agreement-metric semantics change (unavoidable):** the external `agreement_1h` 0–1 *score* is computed by a network-wide observer and **cannot be reproduced from localhost**. Replace it with on-node health signals the cs-ledger canon already alerts on: `proposing` (bool, `server_state=="proposing"`), `amendment_blocked` (bool), and `peer_count`. Keep `amendments_in_majority_window` + `min_gap_to_threshold` (now sourced from `feature`).
- **Run model:** long-running container on the VM (loop every 30s — the canon cadence), not a one-shot job. Co-located with rippled, separate container/user, localhost-only.
- **Metric source resource:** keep `generic_task` with the existing labels so the descriptors/alert policy already deployed in `monitoring.tf`/`poller.tf` keep working for the carried-over metric names.

### Task 1: Capture live admin-RPC fixtures

The exact JSON shape of `feature` and `server_info` on xrpld 3.2.0 must be pinned against real output before writing parsers — do not guess the schema.

**Files:**
- Create: `csyn-consensus-infra/docker/sidecar/testdata/feature.json`
- Create: `csyn-consensus-infra/docker/sidecar/testdata/server_info.json`

- [ ] **Step 1: Pull real `feature` output (read-only, requires named approval).**

```bash
gcloud compute ssh csyn-ldg-validator --zone=us-south1-a --project=csyn-ldg-validator-prod \
  --tunnel-through-iap --command='sudo docker exec rippled sh -c "rippled feature 2>/dev/null || xrpld feature 2>/dev/null"' \
  > csyn-consensus-infra/docker/sidecar/testdata/feature.json
```

- [ ] **Step 2: Pull real `server_info` output.**

```bash
gcloud compute ssh csyn-ldg-validator --zone=us-south1-a --project=csyn-ldg-validator-prod \
  --tunnel-through-iap --command='sudo docker exec rippled sh -c "rippled server_info 2>/dev/null || xrpld server_info 2>/dev/null"' \
  > csyn-consensus-infra/docker/sidecar/testdata/server_info.json
```

- [ ] **Step 3: Inspect the captured `feature` JSON for the amendment voting fields.**

Confirm where per-amendment `enabled` / `vetoed` and the voting fields (`count`, `threshold`, `validations`, `majority`) actually live (top-level `features` map keyed by amendment ID, vs an array). Record the real shape — it drives the parser in Task 2. Expected: a `result.features` object keyed by amendment-ID hash.

- [ ] **Step 4: Commit the fixtures.**

```bash
cd csyn-consensus-infra && git add docker/sidecar/testdata && \
  git commit -m "test(sidecar): capture live feature/server_info fixtures from prod validator"
```

### Task 2: Sidecar module scaffold + `feature` parser (TDD)

**Files:**
- Create: `csyn-consensus-infra/docker/sidecar/go.mod` (module `github.com/csyn/consensus-infra/sidecar`, go 1.25, same monitoring deps as `docker/poller/go.mod`)
- Create: `csyn-consensus-infra/docker/sidecar/main.go`
- Create: `csyn-consensus-infra/docker/sidecar/main_test.go`

**Interfaces:**
- Produces: `extractAmendmentsFromFeature(body []byte) (amendmentStatus, error)` where `amendmentStatus{InMajorityWindow int; MinGapToThreshold int}` (carried verbatim from poller). `gapSentinelNone = 999`.

- [ ] **Step 1: Write the failing test against the real fixture.**

```go
func TestExtractAmendmentsFromFeature(t *testing.T) {
	body, err := os.ReadFile("testdata/feature.json")
	if err != nil { t.Fatal(err) }
	st, err := extractAmendmentsFromFeature(body)
	if err != nil { t.Fatalf("parse: %v", err) }
	if st.MinGapToThreshold < 0 { t.Errorf("gap must be >=0, got %d", st.MinGapToThreshold) }
	// On a quiet network all amendments are enabled -> sentinel.
	// Assert exact values after reading the fixture (fill from real data).
}
```

- [ ] **Step 2: Run it — fails (function undefined).** `cd docker/sidecar && go test ./... -run TestExtractAmendmentsFromFeature -v` → FAIL.

- [ ] **Step 3: Implement `extractAmendmentsFromFeature` against the fixture's real shape.**

Map the `feature` output: skip `enabled==true`; `InMajorityWindow++` when the amendment has a non-null `majority`; `gap = threshold - count` (floored at 0) tracked as the min over amendments with `count>0`; default `MinGapToThreshold = gapSentinelNone`. (Same algorithm as the poller's `extractAmendments`, retargeted at the `feature` JSON struct confirmed in Task 1.)

- [ ] **Step 4: Run it — passes.** `go test ./... -run TestExtractAmendmentsFromFeature -v` → PASS.

- [ ] **Step 5: Commit.** `git add docker/sidecar && git commit -m "feat(sidecar): feature-RPC amendment parser with live-fixture test"`

### Task 3: `server_info` health parser (TDD)

**Files:**
- Modify: `csyn-consensus-infra/docker/sidecar/main.go`, `main_test.go`

**Interfaces:**
- Produces: `extractHealth(body []byte) (health, error)` where `health{Proposing bool; AmendmentBlocked bool; PeerCount int}`.

- [ ] **Step 1: Failing test against `testdata/server_info.json`** asserting `Proposing==true` and `AmendmentBlocked==false` (the live node's known-good state).
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement `extractHealth`** parsing `result.info.server_state` (== "proposing"), `result.info.amendment_blocked` (default false when absent), `result.info.peers`.
- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Commit.** `git commit -am "feat(sidecar): server_info health parser"`

### Task 4: Local RPC client + metric emit loop

**Files:**
- Modify: `csyn-consensus-infra/docker/sidecar/main.go`

**Interfaces:**
- Consumes: `extractAmendmentsFromFeature`, `extractHealth`, `writeSeries` (copy from poller), the metric consts.
- Produces: `callRPC(ctx, method string) ([]byte, error)` POSTing `{"method":method,"params":[{}]}` to `http://127.0.0.1:5005/`.

- [ ] **Step 1: Add metric consts** — keep `metricAmendMajor`, `metricAmendGap`, `metricHeartbeat`; add `metricProposing = "custom.googleapis.com/xrpl/validator/proposing"`, `metricAmendBlocked = "custom.googleapis.com/xrpl/validator/amendment_blocked"`, `metricPeerCount = "custom.googleapis.com/xrpl/validator/peer_count"`. Remove `metricAgreement`, `amendmentsURL`.
- [ ] **Step 2: Implement `callRPC`** — JSON-RPC POST to `127.0.0.1:5005`, 10s timeout, `io.LimitReader` 1<<20, non-200 → error.
- [ ] **Step 3: Implement the 30s loop in `main`** — read `GCP_PROJECT` (required), `METRIC_LOCATION` (default us-south1), `VALIDATOR_TASK_ID` (default validator1); each tick: `callRPC("server_info")` → `extractHealth`, `callRPC("feature")` → `extractAmendmentsFromFeature`; write the 5 series; **heartbeat last**. A failed tick logs and continues (next tick retries) — a missed heartbeat is what `poller_heartbeat` staleness alerts on. Keep `version` handling (`os.Args[1]=="version"` → print `1.0.0`).
- [ ] **Step 4: `go build ./... && go vet ./... && go test ./...`** → all PASS; `./sidecar version` prints `1.0.0`.
- [ ] **Step 5: Commit.** `git commit -am "feat(sidecar): localhost admin-RPC client + 30s metric loop"`

### Task 5: Container image + build workflow

**Files:**
- Create: `csyn-consensus-infra/docker/sidecar/Dockerfile` (mirror `docker/poller/Dockerfile` — distroless static)
- Modify: `csyn-consensus-infra/.github/workflows/build-poller-image.yml` (add a `sidecar` build target, or copy to `build-sidecar-image.yml`) pushing `us-south1-docker.pkg.dev/csyn-ldg-host-dev/csyn-ldg-images/xrpl-sidecar`.

- [ ] **Step 1: Write the Dockerfile** (multi-stage, `gcr.io/distroless/static`, non-root, `ENTRYPOINT ["/sidecar"]`).
- [ ] **Step 2: Local build smoke test.** `docker build -t xrpl-sidecar:dev docker/sidecar` → success.
- [ ] **Step 3: Add the workflow target** (workflow_dispatch input `sidecar_version`).
- [ ] **Step 4: Commit + open PR in sibling.** `git commit`, push branch, `gh pr create`. **Ask before push.**
- [ ] **Step 5: After merge, dispatch the build** (`gh workflow run build-sidecar-image.yml -f sidecar_version=1.0.0`) and **capture the image digest**.

### Task 6: Deploy the sidecar on the VM (Terraform, THIS repo)

**Files:**
- Modify: `ledger-workloads/validator-prod/validator.tf` (or a new `sidecar.tf`) — add the sidecar container to the COS instance config.
- Modify: `ledger-workloads/validator-prod/variables.tf` — add `sidecar_image_digest`.

- [ ] **Step 1: gcp-arch-expert:compute-serverless / observability-sre consult** — confirm the COS multi-container pattern (gce-container-declaration with two containers vs a startup-script `docker run`) used by this instance, and that the runtime SA already holds `roles/monitoring.metricWriter` (it does — `poller.tf` grants it to `poller_runtime`; reuse or grant to the VM SA).
- [ ] **Step 2: Add the sidecar container** sharing the host network namespace (so `127.0.0.1:5005` reaches rippled), env `GCP_PROJECT`, `METRIC_LOCATION`, image pinned by `sidecar_image_digest`. No new firewall/DNS/IAM beyond the existing metricWriter.
- [ ] **Step 3: `tofu plan`** → shows only the sidecar container addition. Review.
- [ ] **Step 4: PR → plan → merge → apply** via `gcp-arch-expert:gcp-tf-apply-flight-control`. **Ask before merge/apply.** Apply uses the clock-safe recreate.
- [ ] **Step 5: Verify** — `gcloud monitoring time-series list` (or console) shows fresh points for `proposing`, `amendment_blocked`, `amendments_in_majority_window`, `min_gap_to_threshold`, `peer_count`, `poller_heartbeat`; the `amendment_in_majority` alert policy is green.

### Task 7: Tear down the dead Cloud Run poller

**Files:**
- Modify/Delete: `ledger-workloads/validator-prod/poller.tf` — remove the Cloud Run job, scheduler, invoker IAM, the two poller SAs, the run-agent AR-reader grant, the `time_sleep`. **Keep** the metric descriptors + the `amendment_in_majority` alert policy (move to `monitoring.tf` if they live in `poller.tf`).
- Modify: `variables.tf` — remove `poller_image_digest` if now unused.

- [ ] **Step 1: Confirm the live scheduler is already paused** (it is) — `gcloud scheduler jobs describe xrpl-validations-poll --location=us-central1` → `PAUSED`.
- [ ] **Step 2: Remove the poller resources; keep the descriptors/alert.**
- [ ] **Step 3: `tofu plan`** → shows destroys of job/scheduler/SAs/IAM only; descriptors + alert unchanged. Review carefully (no descriptor/alert destroy).
- [ ] **Step 4: PR → plan → merge → apply.** **Ask before merge/apply.**
- [ ] **Step 5: Verify** the Cloud Run job + scheduler are gone; alerting still green off sidecar metrics.

---

## Workstream 2 — Out-of-Band UNL Delivery (DESIGN-GATED)

**Status:** NOT plan-ready — one design decision + one VPC-SC/IAM consult must close first. **Deadline 2026-Jul-24.** Runway is comfortable; do WS1 first.

**The problem:** the validator must refresh its publisher-signed UNL without gaining internet egress. The signed list must cross the perimeter as data. The open question is *where the fetch happens* and *how the artifact reaches the node*, because every path crosses the VPC-SC perimeter once and that crossing must be a named, minimal rule — not a widening of egress.

### Task 8: Resolve the delivery design (decision + consult)

- [ ] **Step 1: Decide where the fetcher runs.** It needs internet egress to CloudFront/Cloudflare → it must NOT run in the validator project. Options: (a) an existing egress-capable ops/shared project; (b) a **new** `ledger-ops` project. **If (b), the mandatory new-project-checklist gate applies** (`claude/new-project-checklist.md`, walk item-by-item with Pete). Recommend (a) if a suitable project exists.
- [ ] **Step 2: Decide the artifact transport across the perimeter.** Candidates, each crossing the perimeter once:
  - **Secret Manager** (validator already reads SM via restricted VIP, in-perimeter): fetcher (out-of-perimeter) writes the signed blob → needs a VPC-SC **ingress** rule for the fetcher SA to `secretmanager.googleapis.com` on the validator project. Node reads via existing path. *Cleanest node-side.*
  - **GCS** bucket in-perimeter: same ingress-rule shape for `storage.googleapis.com`; node reads via restricted VIP.
  - **Local mirror only:** a process on the VM serves `http://localhost/vl` from a blob it pulled from SM/GCS — still needs one of the above for the blob to arrive.
- [ ] **Step 3: `gcp-arch-expert:iam-org-policy` + `gcp-arch-expert:networking` consult** — author the exact VPC-SC ingress rule (named fetcher SA, single service, single direction) + the cross-project IAM grant, logged as a deliberate baseline exception. (This is the named-identity ingress pattern the networking consult flagged for the rejected "Option 2".)
- [ ] **Step 4: Confirm the node-side config.** `[validator_list_sites]` points at the internal/localhost source serving the **publisher-signed** list; `[validator_list_keys]` stays (the node verifies the signature regardless of transport, so `http://` to a local source is acceptable per XRPL docs). Validator egress (P2P + restricted VIP) is unchanged.
- [ ] **Step 5: Write the WS2 implementation sub-plan** (fetcher Go in sibling `docker/`, its image build, the ops-project Terraform, the validator config change + clock-safe recreate, end-to-end verify that the node fetches a fresh list and `validators` shows an advanced `expiration`) once Steps 1–4 are decided.

---

## Self-Review

- **Spec coverage:** WS1 covers the broken poller (sidecar replaces it) + teardown; WS2 covers the UNL time-bomb. Both preserve the deny-floor (the locked decision). ✓
- **Agreement-metric gap:** explicitly handled — the external 0–1 score is dropped and replaced with on-node `proposing`/`amendment_blocked`/`peer_count`, which are the canon-baseline alert signals. Documented, not silently dropped. ✓
- **Unknown RPC schema:** handled by capturing live fixtures (Task 1) before writing parsers — no guessed schema in the plan. ✓
- **Type consistency:** `amendmentStatus`/`gapSentinelNone` carried verbatim from the poller; `health` introduced in Task 3 and consumed in Task 4. ✓
- **WS2 honesty:** no fabricated bite-sized steps for the unresolved perimeter-crossing design; it is a decision+consult gate, then a sub-plan. ✓
- **Cross-repo split:** Go/image in sibling, deploy TF here — stated in Global Constraints and per-task file paths. ✓
