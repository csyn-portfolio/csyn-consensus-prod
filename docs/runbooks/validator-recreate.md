# Runbook — Clock-safe validator recreate (config reload / peer-set activation / upgrade) with sync-soak gate

**Scope:** `csyn-ldg-validator` (prod mainnet validator, project `csyn-ldg-validator-prod`).
**Trigger:** any time a staged `rippled.cfg` change (or a binary change) must be loaded
into the **running** validator. *Metadata ≠ live* — a `tofu apply` only writes the new
config to instance metadata; the running daemon keeps its old on-disk copy until the
COS startup re-runs and recreates the container.

**This runbook is general — it has no "currently pending" application.** An earlier
revision pinned one here (the 2026-07-31 peer-set activation), which then rotted into
a description of a state the node had left. Applications are logged in `TASKS.md` as
they happen; this file describes the procedure only.

Per `observability-baseline.md`: `peer_count` target **>= 8**, alert **< 5**, page
**< 3**. This repo's `validator_low_peers` policy warns below **8** — see the block
comment above it in `monitoring.tf` for why canon's `alert < 5` is not adopted
verbatim. For the count right now, run Step 0; a number written here would rot.

## Why a sync-soak gate (read before every recreate)

xrpld **3.2.0** has an **OPEN, not-reproduced-by-XRPLF** report
([XRPLF/rippled#7572](https://github.com/XRPLF/rippled/issues/7572)): a 3.2.0 node can
get stuck in `server_state: connected` acquiring **0 ledger data** on a host where 3.1.3
syncs fine (upstream suspects disk IOPS; no fix, no root cause as of 2026-06-21). A node that is
proposing is **past** this, but a recreate **re-runs the full sync
path**. So every recreate must clear an explicit sync-soak gate (Step 4) before it is
declared done, with the Step-1 snapshot as the rollback point. A node stuck in
`connected` is **not validating** — misses pile up and UNL curators score it down.

## Step 0 — Pre-checks (read-only + named approval to SSH)

**SSH needs the OS Login API turned on first, and off again after.** It is
deliberately DISABLED on the quota project, so a bare `gcloud compute ssh` returns
*"Cloud OS Login API has not been used in project csyn-platform"*. That is the
quota-project corollary — `billing_project = csyn-platform` routes the call through
the platform project, so an API used against a `ledger/` workload must be enabled
there too. The IAM is already standing (`iap.tunnelResourceAccessor` +
`compute.osLogin` on `csyn-ledger-validator-ops@cloudsyn.net`, see `iam.tf`); only
the API is ephemeral.

Run it as a **script**, not as pasted lines. A bare `trap ... EXIT` typed at an
interactive prompt fires when your shell exits, not when the commands finish, so it
would not tear down. The quoted heredoc also keeps the remote command's own quoting
intact through `bash` → `gcloud --command` → `docker exec` → `sh -c`.

```bash
cat > /tmp/validator-precheck.sh <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
trap 'gcloud services disable oslogin.googleapis.com --project=csyn-platform --force -q' EXIT
gcloud services enable oslogin.googleapis.com --project=csyn-platform
gcloud compute ssh csyn-ldg-validator --zone=us-south1-a \
  --project=csyn-ldg-validator-prod --tunnel-through-iap --quiet \
  --command='for c in server_info server_state peers; do echo "=====$c====="; sudo docker exec rippled sh -c "xrpld $c 2>/dev/null || rippled $c 2>/dev/null"; done'
EOS
bash /tmp/validator-precheck.sh
```

Then **verify the teardown** — empty output is the pass. A non-empty result means the
API was left enabled, which is the failure this pattern exists to prevent; disable it
by hand. Do this even on a clean run: a hard-killed terminal skips the trap.

```bash
gcloud services list --enabled --project=csyn-platform \
  --filter="config.name=oslogin.googleapis.com" --format="value(config.name)"
```

If `enable` returns before the API is actually serving, the ssh can still 403. That
is a normal gcloud enablement race — re-run the script; the trap leaves no residue.

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

Poll the node by re-running the Step 0 script — it re-enables OS Login, reads, and tears
down on each pass, so a multi-minute soak leaves the API off between polls. Healthy path
~2 min; **hard
ceiling 10 min**.

```bash
xrpld server_info    # watch server_state advance + complete_ledgers grow
xrpld server_state   # connected → syncing/tracking → full → proposing
xrpld peers          # peer_count recovering; see the PASS floor below
```

**PASS — declare done only when ALL hold within 10 min:**
- `server_state: proposing`
- `pubkey_validator` = our key (token reloaded correctly — not running as a tracking node)
- `complete_ledgers` advancing **and** validations resuming in logs
  (`Advancing accepted ledger … with >= N validations`)
- `peer_count` at or above **8**, the `validator_low_peers` WARN floor — the
  recreate is not done while the node sits in a band its own alert would fire on.
  With `[peer_private] 0` discovery repopulates well past 8; if it stalls below,
  treat it as the discovery-failure case, not as a passing soak. (Under the old
  hard-private posture this line read `>= 3`, which is now below the alert floor.)
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
  `proposing=1`, `unl_active=1`, and `peer_count` at or above 8, the
  `validator_low_peers` WARN floor.
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

> **Registries are INFORMATIONAL — never a PASS/FAIL gate.** This step previously
> read xrpscan's `agreement_1h` via `api.xrpscan.com/api/v1/validator/<key>`, which
> returns HTTP 200 with the body `Error` (verify: `curl -sS -w '%{http_code}\n'
> https://api.xrpscan.com/api/v1/validator/nHUQEd51hNxF3vdVHJKewxZUzXqiP78agDL2bVSiA7Ja4dRFZUGq`),
> and `validations.xrpl.org`, cited elsewhere in this repo, no longer resolves
> (verify: `dig +short validations.xrpl.org`).
>
> A registry can also go dark for a whole **cohort**: on
> 2026-08-04 all 108 domain-verified non-UNL rows on xrpscan were stale, 49 of them
> frozen within the same few minutes of 2026-08-01T22:0xZ across unrelated operators
> and mixed versions, while the domainless non-UNL and UNL rows on the same registry
> kept updating. Our node was SEEN on 3/3 independent validation feeds in the
> measured windows on 2026-08-04 — gating on that registry would have declared a
> 63-hour outage that never happened.
> (The other 107 rows are not claimed healthy; only ours was measured.) Evidence:
> [`TASKS.md`](../../TASKS.md) § "Scanner-invisibility investigation".

---
**Invariants:** snapshot before any node touch; never `docker rm -f` a validator;
deny-floor / VPC-SC untouched; `[validator_token]` is loaded from Secret Manager — verify
`pubkey_validator`, not just `server_state`.

**Follow-on (separate work item, not this runbook):** a **CS-operated peer node** (TBD).
Public-hub pinning is exhausted — all ~5 citable public hubs are already in `[ips_fixed]`,
and only a subset of any pinned list is reliably up at a given time. The reason to want it
has changed: it is no longer the only route to a workable peer count (discovery supplies
that while `[peer_private]` is `0`), but **defense in depth for the case where discovery
fails** — a CS-run peer we dial outbound is a floor that does not depend on public hubs
being healthy. For the count now, run Step 0; an earlier revision of this paragraph
recorded a live figure here and it rotted.
