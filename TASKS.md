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

## BLOCKERS — repo cannot `tofu init`/plan/apply yet (CONSPLIT2 split incomplete)
- **Modules missing.** `validator.tf` sources `../../modules/ledger-service` +
  `ledger-node` → resolve to a `modules/` dir that does NOT exist here (modules
  stayed in sibling `csyn-consensus-infra`, which has **zero tags**). README/CLAUDE
  intent = "referenced by tag from sibling" — NOT implemented. Fix: git-source both
  by pinned tag from the sibling (one home = sibling), add a 2nd GitHub App repo
  scope in CI, update the two `source=` lines. Live infra unaffected.
- **GitHub secrets: NONE set** on csyn-portfolio/csyn-consensus-prod
  (`WIF_PROVIDER_PLAN/APPLY`, `MODULE_READER_CLIENT_ID/APP_PRIVATE_KEY` all absent)
  → CI cannot auth or fetch the substrate module.

## Next (awaiting Pete)
- Decide module strategy (recommend: git-source-by-tag from sibling) + cut sibling tag.
- Set the 4 GitHub secrets (pipe `--body` directly; secret hygiene).
- Then drift-check: first `tofu plan` from this repo should be clean (split = copy).
- Optional: deploy the staged poller; verify email notification channel.
