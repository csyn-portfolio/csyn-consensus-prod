# csyn-consensus-prod — Tasks

Durable task state + cross-repo decision pointers for the Consensus ledger
**prod** workloads repo (split from `csyn-consensus-infra` under CONSPLIT2).

## Decision pointers
- [decision-pointer] CONSPLIT1 → owner: cs/cloud-syndicate-platform/docs/everforge-readiness/decisions/2026-06-16-split-consensus-infra-repo.md
- [decision-pointer] CONSPLIT2 (always-split: practice in csyn-consensus-infra; prod regulated in this repo) → owner: cs/cloud-syndicate-platform/docs/everforge-readiness/decisions/2026-06-20-always-split-consensus-repos.md · index: ~/.ai-decisions.md
- [decision-pointer] CONSVAL1 → owner: cs/cloud-syndicate-platform/docs/everforge-readiness/decisions/ (CONSVAL1)
- [decision-pointer] CONSVAL2 (multi-region validator expansion — EverForge managed-validator product, CS anchor customer; SG asia-southeast1 first, EU deferred; firm geo-nodes in ledger/prod/validators; public-data-only ⇒ outside FedRAMP boundary; extends CONSVAL1+TOPO2) → owner: cs/cloud-syndicate-platform/docs/everforge-readiness/decisions/2026-06-21-multi-region-validator-expansion.md · index: ~/.ai-decisions.md

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
  network_id main, UNL statically pinned, 5 fixed hubs (zaphod added, PR #9), log_level info. ✓
- **Perimeter:** egress DENY-floor @65534 + only tcp:51235 (P2P) & tcp:443 (VIP);
  ingress only IAP-range→22 and P2P 0.0.0.0/0→51235. No public admin/RPC/WS. ✓
- **Reserved P2P EIP** 34.174.33.70 IN_USE. Monitoring: **12 alert policies in code**
  (10 live: down/secret-fail/stuck/poller-down/2×amendment/4×UNL; **+2 from PR #19** —
  `validator_not_proposing` PAGE + `validator_low_peers` WARNING — merged to `main`
  2026-06-30 but **NOT live until `apply.yml` is dispatched**). Channel pete@cloudsyn.net
  (verificationStatus None — confirm email verified).

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

## Incident recovery — 2026-07-31 peer isolation (proposing restored)

**Symptom:** public agreement cliff (`12.38%` day on validations.xrpl.org / xrpscan
`agreement_1h → 0.00000`); sidecar `proposing=false peers=0`; mode `connected`.
**Not** amendment-blocked; `unl_active=1` throughout.

**Root cause:** thin `[ips_fixed]` peer set fully isolated (`peer_private=1`, no
discovery). Both live hub sessions dropped ~2026-07-31 03:35–05:35 UTC; node could
not rejoin. Contributing process debt: PR #23 peer curation **merged 2026-07-24 but
never applied**; VM last started **2026-06-18** so staged zaphod / distributedagreement
never loaded into the running daemon (`metadata ≠ live`).

**Recovery (ops, no new PR):**
1. Applied already-merged #23 via `apply.yml` run
   https://github.com/csyn-portfolio/csyn-consensus-prod/actions/runs/30667187410
   (success) → metadata `ips_fixed` = r.ripple.com, hub.xrpl-commons.org,
   hubs.xrpkuwait.com, zaphod.alloy.ee, hub.distributedagreement.com (sahyadri dropped).
2. Snapshot `validator-pre-recreate-20260731-2136` (data disk, READY).
3. `gcloud compute instances reset csyn-ldg-validator` (boot ~21:38 UTC).
4. Sync-soak: peers→2 within ~1m; `proposing=true` by ~21:44 UTC (~6 min post-boot).
   Sidecar: `ok proposing=true amendment_blocked=false peers=2`.

**Validation evidence (read-only):** Monitoring custom metrics + sidecar
`jsonPayload.message` + xrpscan API. SSH blocked in this session harness — on-box
`server_info`/`peers`/`validators` still recommended for peer identity inventory.

**Still open (structural):** CS-operated peer node for ≥8. Public multi-path pin
([PR #26](https://github.com/csyn-portfolio/csyn-consensus-prod/pull/26)): hostnames
+ measured extra IPs (IAP peers inventory 2026-07-31: 2 stable keys — Ripple +
DA; zaphod/kuwait flap post-handshake).

### Alerting follow-up (why the page felt "missing")
Email **did** deliver to `pete@cloudsyn.net` from `alerting-noreply@google.com`:
LOW PEERS open 2026-07-30 20:02 PDT; NOT PROPOSING open 21:29 PDT; many flappy
STUCK open/resolve pairs all day. Failures were noticeability, not delivery:
- not-proposing omitted `severity` → subject `[ALERT - No severity] proposing 5m-mean…`
- stuck at 15m flapped and buried the page
- Slack second path still gated on Pete token
Harden PR (#25): severity CRITICAL/WARNING + `PAGE:`/`WARN:` prefixes on
**condition display names** (default Monitoring subject form — do **not** set
`documentation.subject`, which can hide ALERT/RESOLVED); stuck → 30m WARNING.
Apply after merge.

## xrpld 3.2.1 upgrade (2026-08-01) — LIVE on prod

**Gate:** Claude r1 **MERGE-WITH-FIXES** (dual-gate; builder Grok) + incident recovery.
- Build: https://github.com/csyn-portfolio/csyn-consensus-infra/actions/runs/30714125224 — `sha256:e664d4c5…`, smoke `xrpld version 3.2.1`.
- Dev soak: svc-rippled-dev on 3.2.1 (SAME digest invariant).
- First prod attempt failed (corrupt overlay2 extract → `exec format error`); emergency 3.2.0 rollback; layerdb orphan purge + clean re-pull with size-proof; container cutover to 3.2.1.
- [x] Live cutover PASS (~4m): `proposing` + `pubkey_validator=nHUQEd51…` + peers≥9 + complete_ledgers advancing + `xrpld version 3.2.1`.
- [x] Snapshots retained: `validator-pre-321-{boot,data}-20260801-1917`.
- [x] Metadata re-pin e664d4c5 — PR #31 merged + apply; staged == live; reboot-safe.
- [x] Final ops check 2026-08-01 ~20:53 UTC: proposing, peers 5–7, sidecar proposing=true, amendment_blocked=false.
- Lesson: after any image pull on COS, **assert binary sizes** (`bash`/`xrpld` non-trivial ELF) before cutover; purge orphan `layerdb` entries if pull fails mid-register.

## Scanner-invisibility investigation — 2026-08-04 (xrpscan ingest break)

**Trigger:** "the XRPL scanners are not seeing our validator." **Verdict: the
validator is healthy and propagating; the staleness is an xrpscan-side ingest
break affecting a whole cohort.** A separate, real config finding fell out of the
investigation (`peer_private`, below) — that one is ours and is worth acting on.

**Rule:** a registry (`xrpscan`, VHS/`data.xrpl.org`, livenet) is INFORMATIONAL.
Never open an incident, and never gate a recreate, on registry `last_seen`. They
fail as a class. The external check is the `validations` stream across **>= 2
independent feeds** — `tools/network-sees-validator.mjs`.

- `OBSERVED: curl https://api.xrpscan.com/api/v1/validators` @ 2026-08-04 ~13:45 UTC
  → cohort freshness: UNL 35/35 fresh; UNL-with-domain 29/29 fresh; non-UNL
  WITHOUT domain 74/162 fresh; **non-UNL WITH domain 0/108 fresh**. Ours is
  non-UNL with domain `validator1.cloudsyndicate.io`.
- `OBSERVED:` same fetch → **49 of those 108 froze inside the 2026-08-01T22:00Z
  hour** across unrelated operators: `xrpsync.com` 22:03:40, `xrplvalidator.alloy.ee`
  22:03:40, **ours 22:02:50**, `zerp.cloud` 22:05:20, `xrpltool.com` 22:05:51; a
  further 37 froze together at 2026-07-30T09Z. Different versions, operators and
  countries, one moment ⇒ registry-side ingest break, not a per-node fault.
- `OBSERVED: node tools/network-sees-validator.mjs --seconds 70` → SEEN on **3/3**
  independent feeds (`xrplcluster.com`, `s2.ripple.com`, `xrpl.ws`), 17-18
  validations each on an unbroken run of 17-18 ledgers @ 2026-08-04 ~14:0x UTC.
- `OBSERVED: server_info / validators / validator_info via IAP` → `proposing`,
  `pubkey_validator` = our master key, `validated_ledger` current, `validator_list
  {count 2, status active}`, `amendment_blocked false`, manifest seq 4 byte-identical
  to xrpscan's @ 2026-08-04 ~12:35 UTC.
- `EXCLUDED: mesh under-propagation` by the 3/3 multi-feed result above.
- `EXCLUDED: amendment-block, UNL expiry, key/manifest divergence, peer isolation,
  inbound firewall` — see the RPC and `nc` evidence in the PR #34 discussion.
- `EXCLUDED: "registries lag non-UNL validators"` (an earlier draft conclusion of
  this very entry) by the cohort table: 74 non-UNL validators are fresh, and VHS's
  non-UNL control carries 308 reports. The correct control is same-cohort, not UNL.
- `EXCLUDED: peer-crawl invisibility as the cause of the staleness` — the privacy
  flag is forced for every validator (below), so all 108 are equally uncrawlable;
  it cannot explain why 162 domainless non-UNL rows update and 108 domain rows do not.
- `OPEN: VHS/data.xrpl.org has NEVER held an agreement report for our key`
  (`.../validator/<key>/reports` → `count: 0`; controls the same hour: UNL 1930,
  non-UNL 308). "Never" is a different class from "went stale" and the xrpscan
  break does not account for it. Not closed.

### Config finding — `[peer_private] 1` is all cost, no benefit (ACT ON THIS)
`OBSERVED:` XRPLF/rippled `src/libxrpl/peerfinder/Config.cpp`:

```cpp
config.peerPrivate  = peerPrivate;                          // from cfg
config.wantIncoming = (!config.peerPrivate) && (port != 0); // ORIGINAL value
if (validationPublicKey) config.peerPrivate = true;         // forced AFTER
config.autoConnect  = !standalone && !peerPrivate;          // ORIGINAL param
```

`wantIncoming` and `autoConnect` are both derived from the **original** config
value; the validator force only flips the privacy flag afterward.

| Config | IP privacy | Discovery | Inbound |
|---|---|---|---|
| validator + `peer_private 0` | **Yes (forced)** | **Yes** | **Yes** |
| validator + `peer_private 1` (current) | Yes | **No** | **No** |

So setting it explicitly buys **no additional privacy** — rippled forces the flag
for any node holding a validation key — and costs discovery and inbound peering.
`OBSERVED:` zero inbound peers in 63.8h of uptime, and 0 of 4 directly-connected
hubs list our IP across ~690 crawl entries (the latter is the forced flag and would
persist either way). This is the mechanism behind the thin peer set that caused the
**2026-07-31 isolation outage** and behind the still-open ">=8 peers" item.

**Canon correction:** `cs-ledger:rippled` § Peer set curation says "a validator MUST
stay `peer_private 1` — rippled forces it internally whenever a validation key is
present." Half true: rippled forces the *privacy flag*, not the *topology
restrictions*. xrpl.org documents `peer_private` as optional — one of three
connection strategies, required only for the proxies and public-hubs configurations.

### Alert scope — external validation visibility (NOT yet built)
`OBSERVED:` Monitoring API → 12 alert policies, all enabled, every one reading an
on-box signal. All were green throughout; none *could* have fired.

- **Signal:** `tools/network-sees-validator.mjs` on a schedule from an egress-capable
  runner (the validator cannot — deny-floor) → `custom.googleapis.com/xrpl/validator/network_sees_us`.
- **Condition:** page only on exit 1 (>= 2 feeds carried untrusted validations and
  none showed us) sustained across >= 3 runs. Exit 2 must NEVER page.
- **Severity:** WARNING. `proposing` already pages for the validating outcome.
- **Do NOT** implement by scraping xrpscan/VHS — that design would have fired a 63h
  false alarm on the cohort break above while the validator was healthy.

## Next
- [ ] **Build the external-visibility alert** (scope above). Terraform in
  `monitoring.tf` + a scheduled runner; T2 dual-gate before merge; Pete-gated apply.
- [x] ~~Merge PR #1~~ — MERGED 2026-06-20.
- [x] ~~Merge substrate PR #204~~ — MERGED 2026-06-20.
- [x] ~~Merge PR #14 (gated Slack notification channel scaffold)~~ — MERGED 2026-06-21 (`21f9d6e`). No-op until `slack_auth_token` supplied.
- [x] ~~Merge PR #19 (not-proposing PAGE + low-peers WARNING alerts)~~ — MERGED 2026-06-30 (`#19`, squash). The response to the 6/30 miss investigation = **page the outcome (`proposing`), warn on peers** (config-only; NOT a node change — validator is healthy). Design via observability-sre consult + high-effort code-review (duration 300s→0s for ~5-7.5m page latency). cs-ledger-feedback captured: "page `peer_count<3`" is alert-debt for a thin-hub validator.
- [x] ~~Pete-gated: dispatch `apply.yml` for PR #19 alerts~~ — policies live (verified 2026-07-31 list).
- [x] ~~Apply PR #23 peer curation + clock-safe recreate~~ — DONE 2026-07-31 (incident recovery above). Snapshot `validator-pre-recreate-20260731-2136`.
- **Pete-only: finish Slack alert path** — still the second notification path (email alone buried the 7/31 page under flappy subjects). Monitoring → Alerting → Notification channels → authorize *Google Cloud Monitoring* Slack app → capture bot token → apply with `-var slack_auth_token=…` (or GH secret wired into apply.yml). Channel name default `#consensus-alerts`.
- WS2-C: re-check UNL expiry advancement after recovery (UNL stayed active through incident; still monitor `unl_max_days_to_expiry`).
- **Peer-set activation recreate — DONE 2026-07-31** (was deferred 6/30; forced by isolation outage). Live peer sessions still ~2; zaphod/distributedagreement now in **loaded** config. Runbook used: [`docs/runbooks/validator-recreate.md`](docs/runbooks/validator-recreate.md). Prior snapshots retained: `validator-pre-recreate-20260630-1258`, `validator-pre-recreate-20260724-0138`, `validator-pre-recreate-20260731-2136`.
- **≥8 peer target → CS-operated peer node (TBD) — still the structural fix.** Public-hub pinning exhausted; thin floor will re-isolate if both live hubs drop again.
- **Process lesson:** merged peer-set / metadata changes require **apply + recreate** before they count as live; track “staged vs loaded” explicitly (do not treat merge as activation).
- **Gap: `validator-buildout-and-domain-verification.md` runbook is still missing** — 5
  `monitoring.tf` alert policies reference it for diagnosis steps (dangling link). The
  recreate steps now live in `validator-recreate.md`; the buildout/domain-verification +
  general node-diagnosis runbook still needs authoring.
- Cleanup (optional): delete `~/Downloads/csyn-module-reader.*.pem` if still on disk; remove stale worktree `/tmp/csyn-plat-consplit2` if present.
