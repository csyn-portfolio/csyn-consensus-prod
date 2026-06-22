# Runbook — UNL break-glass (manual signed-list delivery under the egress deny-floor)

**Scope:** `csyn-ldg-validator` (prod mainnet validator, `csyn-ldg-validator-prod`).
**Trigger:** the `XRPL UNL — node within 7d of losing its trusted validator list`
alert (`unl_max_expiry`), or a confirmed stall where neither publisher list is
refreshing over the peer protocol.

## Background — why this is rarely needed

The validator runs under a VPC-SC **egress deny-floor**: no internet egress
(Cloud NAT disabled), only XRPL P2P (`:51235`) and the Google restricted VIP.
`[validator_list_sites]` is deliberately **absent**; `[validator_list_keys]` pins
both publishers (Ripple `ED2677AB…`, XRPLF `ED42AEC…`).

**The node refreshes its UNL over the XRPL peer protocol** (`TMValidatorList` /
`TMValidatorListCollection`): it accepts, verifies-against-the-pinned-keys, applies,
and re-broadcasts publisher-signed lists relayed by peers — no HTTP fetch required
(verified against rippled 3.2.0 source; see the `cs-ledger:rippled` UNL-posture
canon). It holds **one cached list per publisher** and stays trusted until the
**latest** one expires (`validator_list_threshold` low → one valid list suffices).

So this runbook is a **failsafe**, not routine. It is needed only if P2P refresh
genuinely stalls for **both** publishers (e.g. eclipse / both vetted hubs down +
publishers issuing slowly). The monitoring (`unl_min_days_to_expiry` WARNING,
`unl_max_days_to_expiry` CRITICAL) gives ~weeks of lead time.

## Step 0 — Confirm and diagnose (read-only, named approval to SSH)

```bash
gcloud compute ssh csyn-ldg-validator --zone=us-south1-a \
  --project=csyn-ldg-validator-prod --tunnel-through-iap \
  --command='for c in validators server_info peers; do echo "=====$c====="; \
    sudo docker exec rippled sh -c "xrpld $c 2>/dev/null || rippled $c 2>/dev/null"; done'
```

- `validators` → `result.publisher_lists[]`: per-publisher `available`, `expiration`,
  `seq`. Is one or both expiring? Is `seq` stuck (not advancing)?
- `peers` → are the vetted hubs connected? A thin/eclipsed peer set is the usual
  root cause — **try the cheap fix first:** widen / repair `[ips_fixed]` (see the
  `peer-set-curation` canon) and let P2P deliver. Only proceed to manual delivery
  if peers are healthy but still no fresher list arrives, or expiry is imminent.

## Step 1 — Fetch the current signed list (egress-capable env, NOT the validator project)

From your workstation or an ops box with internet egress:

```bash
# Either publisher; both are pinned. The response is the publisher-SIGNED list blob.
curl -s https://vl.ripple.com   -o /tmp/vl-ripple.json     # ED2677AB…
curl -s https://unl.xrplf.org   -o /tmp/vl-xrplf.json      # ED42AEC…
```

The blob is `{ "blob": "...", "manifest": "...", "signature": "...", ... }`,
publisher-signed. **The node re-verifies the signature against the pinned key**, so
the transport you use to move it does not need to be trusted — but sanity-check you
fetched a fresh one (decode `blob` base64 → JSON → check `expiration`/`sequence`).

## Step 2 — Deliver across the perimeter via an already-permitted path

Do **not** open any new egress. Use the restricted-VIP / GCS path the node already
reaches:

- **GCS (preferred):** put the blob in an in-perimeter bucket the validator SA can
  read via the restricted VIP, then have the node read `file:///` from a local
  mirror it syncs from GCS; **or**
- **Direct to VM:** `gcloud compute scp /tmp/vl-xrplf.json csyn-ldg-validator:/tmp/ …`
  (named approval) and place it on the bind-mounted config path the container sees.

Land it at a stable in-container path, e.g. `/etc/rippled/vl/unl.json`.

## Step 3 — Point the node at the local copy

Add to `rippled.cfg` (via `config/rippled.cfg.tftpl` in this repo — Terraform-owned):

```ini
[validator_list_sites]
file:///etc/rippled/vl/unl.json
# (or) http://127.0.0.1:8080/unl.json   # if served by a localhost mirror

# [validator_list_keys] stays unchanged — the node verifies the publisher
# signature on the blob regardless of how it arrived.
```

PR → `tofu plan` → apply (CI). **Metadata ≠ live:** an apply only stages the new
config on the instance; it is not yet loaded by the running daemon.

## Step 4 — Reload the VALIDATOR (clock-safe recreate)

This is a **validator** config reload, so it is clock-safe (snapshot → drain /
announce → recreate), **never** `docker rm -f`:

1. `gcloud compute disks snapshot` the data disk first.
2. Refresh the on-disk `rippled.cfg` from metadata, then recreate the `rippled`
   container per the upgrade-pattern canon (idempotent COS startup; reboot path).
   (Note: this is the validator, not the harmless sidecar — see
   [`validator-recreate.md`](validator-recreate.md) for the exact recreate steps
   **and the mandatory sync-soak gate**.)

## Step 5 — Verify

```bash
# (same SSH form as Step 0)
xrpld validators   # publisher_lists[].expiration ADVANCED, validator_list.status=active
xrpld server_info  # server_state=proposing, validated_ledger advancing
```

Confirm `unl_max_days_to_expiry` climbs back up in Monitoring and the alert
auto-closes.

## Step 6 — Revert to pure-P2P (optional, after the publisher resumes)

Once P2P refresh is healthy again (peers fixed; publishers issuing), you may remove
the temporary `[validator_list_sites]` to return to the zero-egress baseline — or
leave a `file:///` site pointing at a periodically-refreshed local mirror as a
belt-and-suspenders. Either way the **deny-floor is never modified**.

---
**Invariants:** no new egress rule; no VPC-SC ingress change; deny-floor untouched.
The node's trust root is the pinned `[validator_list_keys]`, not the delivery path.
