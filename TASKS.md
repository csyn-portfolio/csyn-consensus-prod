# csyn-consensus-prod — Tasks

Durable task state + cross-repo decision pointers for the Consensus ledger
**prod** workloads repo (split from `csyn-consensus-infra` under CONSPLIT2).

## Decision pointers
- [decision-pointer] CONSPLIT1 → owner: cs/cloud-syndicate-platform/docs/everforge-readiness/decisions/2026-06-16-split-consensus-infra-repo.md
- [decision-pointer] CONSPLIT2 (always-split: practice in csyn-consensus-infra; prod regulated in this repo) → owner: cs/cloud-syndicate-platform/docs/everforge-readiness/decisions/2026-06-20-always-split-consensus-repos.md · index: ~/.ai-decisions.md
- [decision-pointer] CONSVAL1 → owner: cs/cloud-syndicate-platform/docs/everforge-readiness/decisions/ (CONSVAL1)

## State (post-CONSPLIT2)
- This repo owns `ledger-workloads/validator-prod` + future prod/mainnet roots only.
- Practice/testnet in sibling `csyn-consensus-infra`.
- WIF + principalSet registered in substrate (ID 1275266028).
- Same `ledger-apply` SA (folder-scoped).
- State: `csyn-tf-state` + `ledger-workloads/validator-prod` prefix (no migration).

## Live validator validation — 2026-06-20 (Claude, read-only gcloud/REST evidence)
The mainnet validator was **already applied from the sibling repo before the split**
(state never migrated — `csyn-tf-state/ledger-workloads/validator-prod`, serial 29,
49 resources). It is **live and healthy**. CONSVAL1 shape + readiness rows verified:

- **Node IS validating mainnet** — Cloud Logging (gcplogs): `mode: proposing`,
  "Advancing accepted ledger to 105054543 with >= 28 validations"; logs fresh <10m.
  The dev #11 silent-log fix works (`[debug_logfile]=/dev/stdout` + `enable_gcplogs`).
- **VM (CONSVAL1):** `csyn-ldg-validator` RUNNING, n2d-highmem-8, us-south1-a,
  provisioningModel=STANDARD (never Spot), onHostMaintenance=MIGRATE, automaticRestart,
  Shielded (secureBoot+vTPM+integrity), confidential=absent (by design). ✓
- **Disks:** pd-ssd boot 20 / data 150, both CMEK = `ledger-validator-disk-hsm`. ✓
- **HSM crown-jewel:** disk key + secret key (`ledger-validator-secret-hsm`) both
  protectionLevel=**HSM**, ENABLED (keyring `everforge-validator-hsm-us-south1`,
  csyn-kms). Secret `validator-token` user-managed regional replica, HSM-CMEK. ✓
- **Signing surface:** `[validator_token]` NOT on disk — injected at boot from SM;
  node SA `csyn-ldg-validator-prod-sa` holds secretAccessor only (least-priv). ✓
- **rippled.cfg:** peer_private=1 (NOT relaxed like dev), admin RPC 127.0.0.1 only,
  network_id main, UNL statically pinned, 4 fixed hubs, log_level info. ✓
- **Perimeter:** egress DENY-floor @65534 + only tcp:51235 (P2P) & tcp:443 (VIP);
  ingress only IAP-range→22 and P2P 0.0.0.0/0→51235. No public admin/RPC/WS. ✓
- **Reserved P2P EIP** 34.174.33.70 IN_USE. Monitoring: 5 alert policies enabled,
  channel pete@cloudsyn.net (verificationStatus None — confirm email verified).

### Known-deferred / gaps (not validator defects)
- **Poller (agreement monitoring) is STAGED** — `poller_image_digest=""`, no Cloud
  Run job. The 2 poller-derived alerts (agreement-degraded, poller-down) have no
  data; log-based alerts (down/stuck) are live. Deploy poller to close the gap.
- Notification channel email verification = None — confirm Pete's email is verified
  or alerts won't deliver.

## Repo operability — FIXED on branch `feat/modules-by-tag` (Claude 2026-06-20)
CONSPLIT2 split was incomplete; the controllable parts are now resolved:
- **Modules by tag.** `validator.tf` now git-sources `ledger-service` + `ledger-node`
  from the sibling `csyn-consensus-infra@v0.1.0` (tag cut at b0f422b; one home =
  sibling). ledger-service transitively pulls `service-project` from
  cloud-syndicate-platform@v0.1.0.
- **CI app-token** (plan.yml + apply.yml) now scopes BOTH `cloud-syndicate-platform`
  and `csyn-consensus-infra` (two git insteadOf rewrites, one installation token).
- **Lock restored.** `.terraform.lock.hcl` recovered from sibling pre-split history
  (google/google-beta 6.50.0, time 0.14.0) — not relocked under the mirror (rule #9).
- **DRIFT-CHECK CLEAN.** Local `tofu init` (modules resolve by tag; providers from
  the CS mirror, verified-checksum) + `tofu plan` → **"No changes. Your
  infrastructure matches the configuration."** across all 49 resources. Live == code.

## CI enablement — DONE + VERIFIED (2026-06-20)
- **Substrate applied (Pete-confirmed, flight-control).** PR #204
  (cloud-syndicate-platform) applied two bootstrap roots: `wif/` (6 add → creates
  `gh-csyn-consensus-prod-{plan,apply}` providers + SAs) and
  `bootstrap/org-foundation/` (1 add → the `ledger-apply` principalSet binding).
  Verified live: `ledger-apply` now trusts **both** csyn-consensus-infra AND
  csyn-consensus-prod.
- **All 4 GitHub secrets set** on csyn-consensus-prod: `WIF_PROVIDER_PLAN/APPLY`
  (from the new providers), `MODULE_READER_CLIENT_ID` (Iv23li…), `MODULE_READER_APP_PRIVATE_KEY`.
- **GitHub App** `csyn-module-reader` confirmed installed on the module repos.
- **END-TO-END CI GREEN.** PR #1 plan re-run → all jobs success; CI plan comment:
  **"No changes. Your infrastructure matches the configuration."** PR #1 MERGEABLE/CLEAN.

## Next
- [x] ~~Merge PR #1~~ — MERGED 2026-06-20.
- [x] ~~Merge substrate PR #204~~ — MERGED 2026-06-20.
- [x] ~~Merge PR #14 (gated Slack notification channel scaffold)~~ — MERGED 2026-06-21 (`21f9d6e`). No-op until `slack_auth_token` supplied.
- **Pete-only: finish Slack alert path** — Monitoring → Alerting → Notification channels → authorize *Google Cloud Monitoring* Slack app → capture bot token → apply with `-var slack_auth_token=…` (or GH secret wired into apply.yml). Channel name default `#consensus-alerts`.
- WS2-C: ~1wk re-check UNL expiry advancement (monitoring live; fetcher/ops-prod deferred).
- Cleanup (optional): delete `~/Downloads/csyn-module-reader.*.pem` if still on disk; remove stale worktree `/tmp/csyn-plat-consplit2` if present.
