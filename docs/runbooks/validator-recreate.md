# Runbook — Clock-safe validator recreate (config reload / peer-set activation / upgrade) with sync-soak gate

**Scope:** `csyn-ldg-validator` (prod mainnet validator, project `csyn-ldg-validator-prod`).
**Trigger:** any time a staged `rippled.cfg` change (or a binary change) must be loaded
into the **running** validator. *Metadata ≠ live* — a `tofu apply` only writes the new
config to instance metadata; the running daemon keeps its old on-disk copy until the
COS startup re-runs and recreates the container.

**Current pending application of this runbook — peer-set activation.** `[ips_fixed]`
gained `zaphod.alloy.ee` (PR #9, already applied to instance metadata). Live peer
sessions are **2 of 5** pinned hubs (`r.ripple.com` + `hubs.xrpkuwait.com` peered;
`sahyadri.isrdc.in` down; `hub.xrpl-commons.org` flaky; `zaphod.alloy.ee` staged but
**not yet loaded**). This recreate loads zaphod → expect **≥3** live sessions.
Per `observability-baseline.md`: `peer_count` target **≥8**, alert **<5**, **page <3** —
this recreate **clears the `<3` page condition**. The path to ≥8 is a CS-operated peer
node (see *Follow-on* below); pinning more public hubs is exhausted (all ~5 citable
public hubs are already in `[ips_fixed]`).

## Why a sync-soak gate (read before every recreate)

xrpld **3.2.0** has an **OPEN, not-reproduced-by-XRPLF** report
([XRPLF/rippled#7572](https://github.com/XRPLF/rippled/issues/7572)): a 3.2.0 node can
get stuck in `server_state: connected` acquiring **0 ledger data** on a host where 3.1.3
syncs fine (upstream suspects disk IOPS; no fix, no root cause as of 2026-06-21). Our
node is currently **past** this (proposing), but a recreate **re-runs the full sync
path**. So every recreate must clear an explicit sync-soak gate (Step 4) before it is
declared done, with the Step-1 snapshot as the rollback point. A node stuck in
`connected` is **not validating** — misses pile up and UNL curators score it down.

## Step 0 — Pre-checks (read-only + named approval to SSH)

```bash
gcloud compute ssh csyn-ldg-validator --zone=us-south1-a \
  --project=csyn-ldg-validator-prod --tunnel-through-iap \
  --command='for c in server_info server_state peers; do echo "=====$c====="; \
    sudo docker exec rippled sh -c "xrpld $c 2>/dev/null || rippled $c 2>/dev/null"; done'
```

- **Baseline to compare against:** record current `server_state` (expect `proposing`),
  `pubkey_validator` (= our master key `nHUQEd51hNxF3vdVHJKewxZUzXqiP78agDL2bVSiA7Ja4dRFZUGq`),
  `complete_ledgers`, and `peer_count`.
- **Confirm the staged config is the intended one** — `git main` is applied and the
  `[ips_fixed]` block in `config/rippled.cfg.tftpl` includes `zaphod.alloy.ee`.
- **Confirm the COS startup is idempotent** — it MUST run
  `docker rm -f rippled 2>/dev/null || true` before `docker run`
  (`csyn-consensus-infra` `modules/ledger-node/startup.sh.tftpl`, PR #13). Without that
  guard a reboot collides on the container name, `set -e` aborts the startup script, and
  the **stale container restarts on the OLD config** — a silent no-op. Verify the guard
  before trusting the reset.

## Step 1 — Snapshot the data disk (rollback point)

```bash
# Resolve the data disk name first:
gcloud compute instances describe csyn-ldg-validator --zone=us-south1-a \
  --project=csyn-ldg-validator-prod --format='value(disks[].source.basename())'
# Snapshot it (substitute the data disk + a YYYYMMDD-HHMM stamp):
gcloud compute disks snapshot <DATA_DISK> --zone=us-south1-a \
  --project=csyn-ldg-validator-prod --snapshot-names=validator-pre-recreate-<STAMP>
```

Ledger data is on the bind-mounted data disk, so container removal loses nothing; the
snapshot is the rollback point if the sync-soak gate fails. (For a **binary** change,
snapshot the boot disk too.)

## Step 2 — Pick a low-impact window (clock-safe)

Single validator → a recreate causes a brief miss window (~2 min on the healthy path,
scored by UNL curators). No customer submit-path drains through the validator, so the
"announce" is simply telling ops the agreement score will dip briefly. Pick a quiet
window; do **not** `docker rm -f`.

## Step 3 — Recreate (reboot path, never `docker rm -f`)

```bash
gcloud compute instances reset csyn-ldg-validator --zone=us-south1-a \
  --project=csyn-ldg-validator-prod
```

`reset` re-runs the idempotent COS startup → refreshes the on-disk `rippled.cfg` from
metadata → recreates the `rippled` container with the new `[ips_fixed]`. `complete_ledgers`
will reset and resync even though NuDB persists on the bind-mounted disk.

## Step 4 — SYNC-SOAK GATE (the pass/fail decision)

Poll the node (same IAP-SSH + `docker exec` form as Step 0). Healthy path ~2 min; **hard
ceiling 10 min**.

```bash
xrpld server_info    # watch server_state advance + complete_ledgers grow
xrpld server_state   # connected → syncing/tracking → full → proposing
xrpld peers          # zaphod.alloy.ee should now appear; peer_count ≥ 3
```

**PASS — declare done only when ALL hold within 10 min:**
- `server_state: proposing`
- `pubkey_validator` = our key (token reloaded correctly — not running as a tracking node)
- `complete_ledgers` advancing **and** validations resuming in logs
  (`Advancing accepted ledger … with >= N validations`)
- `peer_count ≥ 3` (zaphod live)
- the **down** (5m no logs) and **stuck** (15m no `LedgerConsensus`) log alerts did not
  fire (or auto-closed)

**FAIL — #7572 signature** (stuck in `connected`, `complete_ledgers` empty / 0 ledger
data beyond ~5–10 min, not advancing):
1. Do **not** leave it stuck — a non-proposing node misses validations and is scored down.
2. **Roll back:** restore the Step-1 snapshot to the data disk and `reset` again
   (for a binary change, revert to the prior digest-pinned image). Re-run this gate.
3. If a clean rollback **still** stalls → **incident.** Capture `server_info` + container
   logs, check the data disk is `pd-ssd` with adequate IOPS (upstream's leading suspect),
   attach evidence to #7572, and hold all 3.2.0 recreates until root cause is established.

## Step 5 — Verify steady state (post-gate)

- Dashboard `3fa8610d-1b5f-4440-a04c-d53a54ae6ab7` (`csyn-ldg-validator-prod`):
  `proposing=1`, `peer_count ≥ 3`, `unl_active=1`.
- **The network sees our validations** — run from any machine with internet
  (the validator itself cannot reach this under the egress deny-floor).
  **Run it twice, a few minutes apart** — a single window is statistically weak,
  because a feed relaying trusted-only validations in that window cannot show an
  untrusted validator at all:

  ```bash
  # after a token rotation, first read the current signing key:
  #   xrpld validator_info   ->  .ephemeral_key   (pass as --signing-key)
  node tools/network-sees-validator.mjs --seconds 70
  # exit 0 = SEEN on >=2 independent feeds · 1 = NOT SEEN (meaningful) · 2 = INCONCLUSIVE
  ```

  PASS requires **exit 0 on two consecutive runs**. It subscribes to the
  `validations` stream on three independent public rippled nodes; an observation
  at a node with no peering relationship to us proves our validation left the box
  and crossed the overlay on that path. Requiring >= 2 feeds is what distinguishes
  multi-path propagation from a single lucky path.

  Handling the other exits — neither is a reason to recreate on its own:

  | Exit | Meaning | Do |
  |---|---|---|
  | `2` | INCONCLUSIVE — feeds were relaying trusted-only, or a feed errored | Re-run up to **3 times**, widening `--seconds` (e.g. 70 → 150). Still exit 2 after 3 tries → escalate as a *diagnostic* gap, not a node fault; the recreate PASS stays unproven either way. |
  | `1` | NOT SEEN — >= 2 feeds carried untrusted validations and none showed us | **Before escalating:** confirm on-box `server_state: proposing` and `pubkey_validator` = our master key, and confirm `--signing-key` matches `validator_info.ephemeral_key` (a rotated token with a stale default is the most likely cause of a false exit 1). |
- The `peer_count < 3` page condition is cleared.

> **Registries are INFORMATIONAL — never a PASS/FAIL gate.** This step previously
> read xrpscan's `agreement_1h` via `api.xrpscan.com/api/v1/validator/<key>`, which
> returns HTTP 200 with the body `Error` (verify: `curl -sS -w '%{http_code}\n'
> https://api.xrpscan.com/api/v1/validator/nHUQEd51hNxF3vdVHJKewxZUzXqiP78agDL2bVSiA7Ja4dRFZUGq`),
> and `validations.xrpl.org`, cited elsewhere in this repo, no longer resolves
> (verify: `dig +short validations.xrpl.org`).
>
> A registry can also go dark for a whole **cohort** while the nodes are fine: on
> 2026-08-04 all 108 domain-verified non-UNL rows on xrpscan were stale, 49 of them
> frozen within the same few minutes of 2026-08-01T22:0xZ across unrelated operators
> and mixed versions, while the domainless non-UNL and UNL rows on the same registry
> kept updating. Our node was SEEN on 3/3 independent validation feeds throughout —
> gating on that registry would have declared a 63-hour outage that never happened.
> (The other 107 rows are not claimed healthy; only ours was measured.) Evidence:
> [`TASKS.md`](../../TASKS.md) § "Scanner-invisibility investigation".

---
**Invariants:** snapshot before any node touch; never `docker rm -f` a validator;
deny-floor / VPC-SC untouched; `[validator_token]` is loaded from Secret Manager — verify
`pubkey_validator`, not just `server_state`.

**Follow-on (separate work item, not this runbook):** the path to the `≥8` peer target is
a **CS-operated peer node** (TBD) — public-hub pinning is exhausted (all ~5 citable public
hubs already in `[ips_fixed]`). Until then, a 5-hub `[ips_fixed]` with zaphod live floats
around 3 reliable sessions, which clears the page line but stays in `<5` ticket territory.
