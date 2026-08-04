# validator-prod — prod XRPL validator (foundation + deferred VM sprint)

Standalone **mainnet** XRPL validator project under `ledger/prod`. This root lives
in the **prod regulated repo** (`csyn-consensus-prod`) per CONSPLIT2 (2026-06-20).
Foundation-only at time of split: project + dedicated workload SA + isolated VPC +
CMEK + Secret Manager + restricted-VIP DNS + essential contacts.

(The VM sprint shapes are fixed as module inputs here.)

## Read before building the prod validator (or any prod feeder/Clio)

Prod **must inherit every lesson** from the practice estate. Do not author prod
workloads without these:

- **[../../docs/dev-to-prod-readiness.md](../../docs/dev-to-prod-readiness.md)**
  (or its neutral home) — the cross-repo carry-forward plan. **Controlling doc.**
- Practice lessons now live in the sibling `csyn-consensus-infra` repo.
- **cs-ledger canon** (authoritative ops): `cs-ledger:rippled` (validator key
  model, Confidential VM + HSM posture, `[port_grpc]` + `[port_ws_public]` feeder
  contract), `cs-ledger:custody` (signing-surface HSM), `cs-ledger:clio` (tier-1
  Clio shape if a prod read-path is added), `cs-ledger:evidence` +
  `cs-ledger:observability` (audit packets, SLOs), `cs-ledger:regulatory`.
- **Repo guardrails:** [../../claude/new-project-checklist.md](../../claude/new-project-checklist.md)
  (mandatory, item-by-item with Pete before any `google_project` apply),
  bootstrap-class org-foundation applies (Pete-apply-only).

## Dev lessons that apply directly here (see readiness doc for the full table)

- **Validator-specific:** `[validation_seed]` lives in an **HSM**, never on disk
  (distinct from the dev tracking node); `provisioning_model = STANDARD` (never
  Spot — dUNL clock continuity); `peer_private = 0` — this restores discovery and
  inbound, and it does **not** keep the validator's address private: the forced
  privacy flag buys only how we present ourselves — absence from Peer Crawler
  (`/crawl`) and the handshake Crawl header — while our address still propagates
  via endpoint gossip. Read the `[peer_private]` stanza in
  `config/rippled.cfg.tftpl` before changing it; that stanza is the one home for
  the trade-off. Slot bounds are set explicitly alongside it. The dev tracking node's config also
  sets `0`, but for a different reason — do not treat the two as interchangeable; deletion_policy PREVENT + sensitive data-classification (already set).
- **NuDB durability across restart** (dev lesson #11): a dev xrpld came back
  `complete_ledgers: empty` after a VM reset — confirm the validator's ledger store
  survives reboot/maintenance before relying on it; STANDARD (non-Spot) + persistent
  disk is part of why the validator must not be Spot.
- **If a prod rippled feeder + Clio read-path is added** (tier-1 shape): the feeder
  needs **both** `[port_grpc]` and `[port_ws_public]` (dev lesson #4); Clio
  `dos_guard.whitelist` takes **bare IPs, not CIDR** (#3); Scylla mount ownership
  `999:1000` (#1); config-as-file bind-mount (#2); `allow_no_etl` ordering (#5).
- **Universal:** observability from day one (gcplogs / Cloud Logging + the SA's
  `logging.logWriter`) (#6); IAP admin path, no bastion (#7); xrpld config comments
  on their own line (#9); image digests via the CS AR mirror + CMEK + BinAuth (#10);
  never churn a reserved IP via an immutable-field (e.g. address `description`) edit
  (#8).
