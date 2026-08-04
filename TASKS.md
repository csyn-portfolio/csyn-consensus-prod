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

## Scanner-invisibility investigation — 2026-08-04 (root cause NOT established)

**Trigger:** "the XRPL scanners are not seeing our validator." **Verdict: the
validator is healthy and validating; the two registries re-queried this session
(xrpscan, VHS) both fail to show it current; the reason is NOT established.**

> [!IMPORTANT]
> **Retraction.** The version of this entry merged in `pr:34` concluded the ongoing
> staleness was "specific to xrpscan's domain-verified non-UNL path." **That is
> withdrawn.** The withdrawal rests on **one** leg, re-queried this session: VHS
> returns no record for the key at all, and an ingest break inside xrpscan cannot
> account for a *different* registry that has no row to freeze. (xrpscan's own
> freeze is consistent with the withdrawn conclusion and is not evidence against
> it — it is the observation that conclusion was built on.) A third data point
> (bithomp, stale from an unrelated date) points the same way but comes from the
> **prior session and could not be re-executed here**, so it is not load-bearing.
> The cohort observations
> below are retained as measurements; the conclusion drawn from them is not.

**Rule (unchanged, and the one durable output):** a registry (`xrpscan`,
VHS/`data.xrpl.org`, bithomp, livenet) is INFORMATIONAL and cannot be a sole
PASS/FAIL gate. Never open an incident, and never gate a recreate, on registry
`last_seen`. The external check is the `validations` stream across **>= 2
independent feeds** — `tools/network-sees-validator.mjs`.

### Node health — re-verified, not inferred

- `OBSERVED: node tools/network-sees-validator.mjs --seconds 70` @ 2026-08-04
  ~15:52 UTC → SEEN on **3/3** independent feeds (`xrplcluster.com`,
  `s2.ripple.com`, `xrpl.ws`), 17 validations each on an unbroken run of 17
  ledgers.
- `OBSERVED: node tools/network-sees-validator.mjs --seconds 70` @ 2026-08-04
  ~14:0x UTC → SEEN on the same 3/3 feeds, 17-18 validations each on an unbroken
  run of 17-18 ledgers. Two independent runs ~1.8h apart, same outcome.
- `OBSERVED: server_info / validators / validator_info via IAP` @ 2026-08-04
  ~12:35 UTC → `proposing`, `pubkey_validator` = our master key,
  `validated_ledger` current, `validator_list {count 2, status active}`,
  `amendment_blocked false`, manifest seq 4 byte-identical to xrpscan's.
- `EXCLUDED: single-path-only propagation` by the 3/3 multi-feed result.
  Independent public feeds — strong multi-path evidence, not a full-mesh proof.
- `EXCLUDED: amendment-block, UNL expiry, key/manifest divergence, current peer
  isolation, inbound firewall as causes of NON-VALIDATION` — RPC and `nc` evidence
  in the `pr:34` discussion. Scoped deliberately: this says the node is validating
  now, not that peer topology is irrelevant to the registry question or to the
  2026-07-31 outage.

### Registry state — xrpscan + VHS re-verified here, bithomp carried forward

- `OBSERVED: curl -sL https://api.xrpscan.com/api/v1/validatorregistry` @
  2026-08-04 ~15:52 UTC (note `/api/v1/validators` 302s to this) → our row
  `last_seen 2026-08-01T22:02:50.828Z`, `ledger_index 106007196`, version 3.2.1,
  domain `validator1.cloudsyndicate.io`. **Byte-identical `last_seen` to the
  ~13:45 UTC read ~2h earlier; ~66h stale as of this read.**
- `OBSERVED: curl https://data.xrpl.org/v1/network/validator/<key>/reports` @
  2026-08-04 ~15:52 UTC → `{"result":"success","count":0,"reports":[]}`.
  `SEARCHED: .../v1/network/validators` (305 rows) same minute for our master key
  → **absent**. So VHS currently holds **no row and no reports** for us — a
  different failure from a stale row. Controls read the same day: UNL 1930
  reports, non-UNL 308.
  `OPEN:` whether VHS ever held a record. The two calls above read **present**
  state; no VHS history endpoint was queried, so "never" is not earned here.
- `OBSERVED: bithomp validator lookup, exact endpoint unrecorded` @ 2026-08-04
  ~14:xx UTC (**prior session, not re-executed here**) → stale since **2026-07-31T02:45**, still advertising version **3.2.0** —
  a version we left on 2026-08-01 (see the 3.2.1 pin above), i.e. a different
  freeze date from xrpscan's.
  `not observable: https://bithomp.com/api/cors/v2/validators returns HTTP 403`
  unauthenticated, and `https://bithomp.com/validator/<key>` returns HTTP 204 with
  a 0-byte body (client-rendered). Treat this bullet as corroborating only. For
  what the retraction is licensed by, read the Retraction callout above — this
  bullet does not restate it.

### Cohort measurements (retained; the conclusion built on them is withdrawn)

- `OBSERVED:` the ~13:45 UTC xrpscan fetch → cohort freshness: UNL 35/35 fresh;
  UNL-with-domain 29/29 fresh; non-UNL WITHOUT domain 74/162 fresh; **non-UNL WITH
  domain 0/108 fresh.** Ours is non-UNL with domain.
- `OBSERVED:` same fetch → **49 of those 108 froze inside the 2026-08-01T22:00Z
  hour** across unrelated operators: `xrpsync.com` 22:03:40, `xrplvalidator.alloy.ee`
  22:03:40, **ours 22:02:50**, `zerp.cloud` 22:05:20, `xrpltool.com` 22:05:51; a
  further 37 froze together at 2026-07-30T09Z. `INFERRED:` that geometry is
  incompatible with 49 independent node faults — mixed versions freezing in the
  same minute, `ledger_index` still advancing across the window, and the domainless
  non-UNL and UNL rows on the SAME registry continuing to update. It is not
  evidence that all 108 nodes were healthy; only ours has multi-feed proof.
- `EXCLUDED: H5 "an upstream feed shared by BOTH registries is still stale"` by
  cross-registry divergence @ 2026-08-04 ~14:2x UTC: `zerp.cloud` and
  `xrplvalidator.alloy.ee` frozen on xrpscan at 2026-08-01T22:0x yet LIVE on VHS,
  `current_index` 106066864/106066865, `agreement_1h` 1.00000 / 0.99784.
- `EXCLUDED: peer-crawl invisibility as the discriminator for the xrpscan cohort
  freeze` — the privacy flag is forced for every validator (below), so all 108 are
  equally uncrawlable; it therefore does not distinguish the 162 domainless non-UNL
  rows that update from the 108 domain rows that do not. **Scope note:** this rules
  crawl-invisibility out as the *split* explanation for the cohort freeze; it does
  not rule out a crawl-related contribution generally, and says nothing about our
  own absence from VHS.

### What remains open

- `OPEN:` **root cause.** Nothing observed so far is confirmed as the cause; the
  candidates below are open, not eliminated.
- `OPEN:` untested candidate — **our node specifically is under-observed
  because it is hard-private: zero inbound, no discovery, reachable only by the
  peers it dials out to.** Untested. Note this is the *narrow* claim about our
  node, not the general one below.
- `EXCLUDED (still holds): "registries lag non-UNL validators as a class"` by the
  same-registry cohort table — 74/162 domainless non-UNL rows fresh on the xrpscan
  fetch, and VHS non-UNL controls carrying 308 reports. Silence about **us** on VHS
  does not touch those controls. The general exclusion stands; only
  the narrower per-node hypothesis above is open.
- `OPEN: H5b "a shared event at freeze ONSET (2026-08-01T22:0x)"` — the
  cross-registry discriminator ran at the ~14:2x UTC check, ~64h after onset, and
  cannot reach back; no VHS `last_seen` history at onset is available to us.
- `INCONCLUSIVE:` the intended discriminator (IP-resolvability vs registry
  freshness across the cohort) **returned n=0 in the comparison cohort and never
  actually ran.** Not evidence either way.
- **The uncontrolled discriminator has now run.** `peer_private 0` was applied and
  loaded on 2026-08-04 (see the post-apply section below), which varied this
  candidate's variable — inbound reachability and discovery. It also changed peer
  identity and topology at the same time, so it is not a controlled test: if
  registry freshness recovers, that supports the candidate but does not prove it,
  and if it does not recover, that weakens the candidate without eliminating it.
  Nobody should build on either outcome without saying which.

### Config finding — `[peer_private]` is SOFT-forced (mechanism; see decision below)
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
| validator + `peer_private 1` (pre-A) | Yes | **No** | **No** |

So setting it explicitly buys **no additional privacy** — rippled forces the flag
for any node holding a validation key — and costs discovery and inbound peering.
`OBSERVED:` zero inbound peers in 63.8h of uptime, and 0 of 4 directly-connected
hubs list our IP across ~690 crawl entries (the latter is the forced flag and would
persist either way). `INFERRED:` hard-private plus a thin `[ips_fixed]` set is
sufficient mechanism for the **2026-07-31 isolation outage** and for the still-open
">=8 peers" item; the postmortem above already names peer-set thinness as the cause,
so treat this as the config reason that thinness had no discovery to fall back on.

**Canon correction:** `cs-ledger:rippled` § Peer set curation says "a validator MUST
stay `peer_private 1` — rippled forces it internally whenever a validation key is
present." Half true: rippled forces the *privacy flag*, not the *topology
restrictions*. xrpl.org documents `peer_private` as optional — one of three
connection strategies, required only for the proxies and public-hubs configurations.

**Exposure correction (this cost a wrong approval).** An earlier framing of this
finding said the forced privacy flag stops peers gossiping our address. It does
not. `OBSERVED:` at the deployed tag XRPLF/rippled 3.2.1,
`src/xrpld/peerfinder/detail/Logic.h` inserts an entry for **ourselves at hops=0**
into the endpoint handout to every target when `config_.wantIncoming &&
counts_.inMax() > 0`; recipients substitute our real socket address and relay it
onward via the Livecache. `wantIncoming` is exactly what `peer_private 0` turns on.
So under `peer_private 0` our address reaches nodes we never dialled. What the
forced flag does buy is narrower: absence from Peer Crawler (`/crawl`) results.

**DECISION — Pete, 2026-08-04: option A, `peer_private 0`.** Three options were on
the table: (A) flip `peer_private` to 0; (B) build a CS-operated proxy tier in
front of the validator, the posture xrpl.org prescribes for institutional
validators; (C) neither. **B was declined** — no proxies. **A was chosen**, and
shipped via `pr:38`. (An earlier reading of the same day's instruction recorded both
as declined; that was a misreading of "no proxies" as declining everything, and is
corrected here.)

**The reason to take A is the outage, not the scanners.** Under `peer_private 1`
`autoConnect` is off, so when both live hub sessions dropped on 2026-07-31 the node
had no discovery to fall back on and went fully isolated — see the incident section
above. That is a proven failure mode with a proven cost. Whether A also restores
the registry listing is **unproven** and is not the warrant for this change.

**The exposure.** Under `peer_private 0` two things increase attack surface:
rippled **accepts inbound peer sessions from strangers** (`wantIncoming` goes true),
and our address is **pushed into endpoint gossip** so nodes we never dialled learn
it (mechanism above). A third thing changes but is not exposure — `autoConnect`
turns on, which is outbound discovery, and is the reliability property A is being
taken for.

One bound survives: the privacy flag is still forced for a validation-key node, so
we stay absent from Peer Crawler (`/crawl`) either way.

What the firewall does **not** buy us. `OBSERVED: gcloud compute firewall-rules list
--project=csyn-ldg-validator-prod` @ 2026-08-04 → `csyn-ldg-validator-p2p-in`,
INGRESS, source `0.0.0.0/0`, `tcp:51235`, `DISABLED=False`. That establishes only
that **A is not a firewall change** — the L4 surface is identical before and after.
It does **not** mean we are already peer-reachable: under `peer_private 1` no peer
session forms with a stranger, though the L4 connection may still be accepted. Do
not read the open port as "the exposure was already there" — that
conflates L4 reachability with peer-layer reachability, and the peer layer is
exactly what A opens.

**Applying was not merging.** The path taken was: T2 dual-gate → merge →
Pete-gated `apply.yml` dispatch → clock-safe recreate with a snapshot first, per
[`docs/runbooks/validator-recreate.md`](docs/runbooks/validator-recreate.md). All
four steps completed on 2026-08-04; the evidence is in the post-apply section
below.

### Alert scope — external validation visibility (scope implemented in `pr:36`)
Scope below is implemented in `pr:36`. Whether it is live is not recorded here —
verify with `gcloud alpha monitoring policies list --project=<validator project>`;
merging `pr:36` does not apply it.

`OBSERVED:` Monitoring API → 12 alert policies, all enabled, every one reading an
on-box signal. All were green throughout; none *could* have fired.

- **Signal:** `tools/network-sees-validator.mjs` on a schedule from an egress-capable
  runner (the validator cannot — deny-floor) → `custom.googleapis.com/xrpl/validator/network_sees_us`.
- **Condition:** page only on exit 1 (>= 2 feeds carried untrusted validations and
  none showed us) sustained across >= 3 runs. Exit 2 must NEVER page.
- **Severity:** WARNING. `proposing` already pages for the validating outcome.
- **Do NOT** implement by scraping xrpscan/VHS — that design would have fired a 63h
  false alarm on the cohort break above while the validator was healthy.

## Option A applied and live-verified — 2026-08-04

`peer_private 0` + explicit slot bounds shipped (`pr:38`, which superseded the
un-reopenable `pr:35`), applied, and loaded onto the daemon running at the time of the checks below. Sequence and
evidence below; for current state run the commands, do not read the numbers here.

- `OBSERVED: gh workflow run apply.yml -f configs=ledger-workloads/validator-prod`
  → run 30950653638 completed success @ 2026-08-04 ~21:05 UTC.
- `OBSERVED: gcloud compute instances describe csyn-ldg-validator --zone=us-south1-a
  --project=csyn-ldg-validator-prod` metadata `rippled-cfg` → `[peer_private] 0`,
  `[peers_out_max] 20`, `[peers_in_max] 10`. Metadata only at this point — the
  daemon was still on its old on-disk copy.
- `OBSERVED:` startup-script metadata contains `docker rm -f rippled 2>/dev/null
  || true` before `docker run`, and rewrites `/etc/opt/ripple/rippled.cfg` from
  metadata every boot. Checked BEFORE the reset: without that guard the reset is a
  silent no-op on the old config.
- `OBSERVED:` snapshot `validator-pre-recreate-20260804-2105` (150 GB) READY before
  the reset — the rollback point.
- `OBSERVED: gcloud compute instances reset` @ 21:06:29 UTC. Sidecar reached
  `proposing=true` @ 21:13:54 UTC — **~7.4 min, inside the runbook's 10-min
  ceiling** but well past the ~2 min healthy path.
- `OBSERVED:` sidecar peer count 9 (pre-reset) → 28 by ~21:10 UTC, before proposing returned → 38
  @ 21:21:54 UTC. `INFERRED:` **both** autoConnect and inbound were live at that
  reading, from the shipped caps: `[ips_fixed]`'s 11 endpoints bypass slot
  accounting and sit outside the maxima, so an all-outbound ceiling is 11 + 20 = 31.
  A count of 38 therefore requires at least 7 inbound sessions, and requires
  discovery to have filled outbound beyond the fixed floor. Neither alone reaches 38.
- `OBSERVED:` `Advancing accepted ledger to 106073444 with >= 29 validations` @
  21:19:21 UTC — validations resumed.
- `OBSERVED: node tools/network-sees-validator.mjs --seconds 70` twice, ~2 min
  apart @ ~21:19 and ~21:21 UTC → SEEN on 2/3 then 3/3 independent feeds, 18/18
  ledgers unbroken each. The runbook's two-consecutive-exit-0 gate: PASS.
- `SEARCHED:` sidecar log stream for `^warn ` / `^err ` since 21:06:35Z → none.

### Open after this change

- `OBSERVED: min_gap` read **14** before the reset, **999** from the reset through
  21:21:54 UTC, and **14** again by 21:33:24 UTC — so it recovered on its own after
  roughly 20 minutes, with `in_majority` **0** throughout. It tripped no alert and
  no `warn`/`err` line. `OPEN:` what the field measures is still not established —
  the sidecar emitting it lives in the sibling repo `csyn-consensus-infra`, out of
  scope for the applying session. The recovery is consistent with a sentinel used
  while the value cannot be computed during resync, but that is a guess, not a
  reading of the source. Worth settling before the next recreate, when it will
  almost certainly show 999 again and should not be mistaken for a fault.
- `OPEN:` **per-session inventory**, not the existence of inbound. That inbound
  sessions existed is inferred from the caps arithmetic above. What was not obtained is the
  breakdown — which peers, which direction each, how many inbound at a given moment,
  and whether any single source is consuming slots. `not observable: gcloud compute
  ssh --tunnel-through-iap` fails with OS Login API not enabled on quota project
  `csyn-platform`, so the `peers` admin RPC could not be run. Enabling that API is a
  Terraform change in `cloud-syndicate-platform`, deliberately not done ad hoc.
- [ ] **Re-baseline the low-peers threshold.** It is 2.5, set for an outbound-only
  node whose equilibrium was ~2. Post-discovery the count is an order higher, so
  the WARN can no longer fire before a serious degradation. Re-baseline after
  24-48h of post-recreate data, per the note in `monitoring.tf`.
- [ ] **Registry watch, no action implied.** Whether the scanner listing recovers is
  the uncontrolled discriminator described above. It was NOT the warrant for this
  change and nothing further should be built on it either way.

## Next
- [x] ~~`peer_private 0`~~ — shipped as `pr:38` (`pr:35` could not be reopened
  after its branch was deleted), applied and loaded 2026-08-04. See the post-apply
  section above for the evidence and what it left open.
- [ ] **`pr:36` external-visibility alert** — T2 dual-gate (Grok), then merge, then
  Pete-gated `apply.yml` dispatch. Gate state is on the PR body, not here.
- [x] ~~Correct the two false operator-facing comments in
  `ledger-workloads/validator-prod/config/rippled.cfg.tftpl`~~ — landed in `pr:38`
  alongside the value change, so the file never described a posture it was not in.
- Not planned: the CS-operated proxy tier (declined 2026-08-04). Reopening it would
  need a fresh decision; the mechanism and trade-off are recorded above so it does
  not have to be re-derived.
- [x] ~~Merge PR #1~~ — MERGED 2026-06-20.
- [x] ~~Merge substrate PR #204~~ — MERGED 2026-06-20.
- [x] ~~Merge PR #14 (gated Slack notification channel scaffold)~~ — MERGED 2026-06-21 (`21f9d6e`). No-op until `slack_auth_token` supplied.
- [x] ~~Merge PR #19 (not-proposing PAGE + low-peers WARNING alerts)~~ — MERGED 2026-06-30 (`#19`, squash). The response to the 6/30 miss investigation = **page the outcome (`proposing`), warn on peers** (config-only; NOT a node change — validator is healthy). Design via observability-sre consult + high-effort code-review (duration 300s→0s for ~5-7.5m page latency). cs-ledger-feedback captured: "page `peer_count<3`" is alert-debt for a thin-hub validator.
- [x] ~~Pete-gated: dispatch `apply.yml` for PR #19 alerts~~ — policies live (verified 2026-07-31 list).
- [x] ~~Apply PR #23 peer curation + clock-safe recreate~~ — DONE 2026-07-31 (incident recovery above). Snapshot `validator-pre-recreate-20260731-2136`.
- **Pete-only: finish Slack alert path** — still the second notification path (email alone buried the 7/31 page under flappy subjects). Monitoring → Alerting → Notification channels → authorize *Google Cloud Monitoring* Slack app → capture bot token → apply with `-var slack_auth_token=…` (or GH secret wired into apply.yml). Channel name default `#consensus-alerts`.
- WS2-C: re-check UNL expiry advancement after recovery (UNL stayed active through incident; still monitor `unl_max_days_to_expiry`).
- **Peer-set activation recreate — DONE 2026-07-31** (was deferred 6/30; forced by isolation outage). Live peer sessions still ~2; zaphod/distributedagreement now in **loaded** config. Runbook used: [`docs/runbooks/validator-recreate.md`](docs/runbooks/validator-recreate.md). Prior snapshots retained: `validator-pre-recreate-20260630-1258`, `validator-pre-recreate-20260724-0138`, `validator-pre-recreate-20260731-2136`.
- **≥8 peer target → CS-operated peer node (TBD) — still the peer-diversity fix.** Public-hub pinning exhausted. **Under `peer_private 1`** the thin floor re-isolates if both live hubs drop again, because there is no discovery fallback; once option A is applied `autoConnect` supplies a fallback, which reduces that failure mode without erasing isolation risk, and the weight of this item shifts toward peer diversity. Distinct from the declined proxy tier: this is a peer the validator dials **outbound**, compatible with either `peer_private` value.
- **Process lesson:** merged peer-set / metadata changes require **apply + recreate** before they count as live; track “staged vs loaded” explicitly (do not treat merge as activation).
- **Gap: `validator-buildout-and-domain-verification.md` runbook is still missing** — 5
  `monitoring.tf` alert policies reference it for diagnosis steps (dangling link). The
  recreate steps now live in `validator-recreate.md`; the buildout/domain-verification +
  general node-diagnosis runbook still needs authoring.
- Cleanup (optional): delete `~/Downloads/csyn-module-reader.*.pem` if still on disk; remove stale worktree `/tmp/csyn-plat-consplit2` if present.
