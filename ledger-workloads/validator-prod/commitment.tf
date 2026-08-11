# Committed use discount — 1 year, resource-based, N2D, us-south1.
#
# WHETHER AN APPLY OF THIS ROOT BUYS ANYTHING IS NOT STATED HERE. It is `enable_n2d_cud`
# in variables.tf, and whether the commitment already exists. Read both — do not trust a
# sentence in this header, including this one, to tell you the current position:
#
#   grep -A4 'variable "enable_n2d_cud"' variables.tf     # true => an apply purchases
#   gcloud compute commitments list \
#     --project=csyn-ldg-validator-prod --regions=us-south1  # non-empty => already bought
#
# This paragraph replaced three successive attempts to state the answer in prose, each of
# which was correct when written and false within a day. #49 said "GATED OFF BY DEFAULT…
# merging buys nothing"; #50 flipped the flag and that became an invitation to buy by
# accident (caught by the gate, not by me); the replacement said "LIVE AND ARMED", which
# the very next change falsified again. A value with one home in variables.tf does not get
# a second home in a comment.
#
# What does not change, and is therefore safe to write down: this root is dispatched by
# apply.yml with a `configs` input, so an apply started for the dashboard diff, an API
# enablement, or anything else in this directory is capable of creating the obligation as
# a side effect. Check the two commands above before dispatching, every time.
#
# The COMMITMENTS regional quota is no longer a backstop. It was 0 when #49 was written,
# which made an accidental apply fail closed; that is no longer the case.
#   OBSERVED: gcloud compute regions describe us-south1 --project=csyn-ldg-validator-prod
#     -> COMMITMENTS limit=1.0 usage=0.0, raised from 0.0 the same day; control
#     CPUS limit=750.0 confirms the probe reads live values @ 2026-08-11
# COMMITMENTS caps the NUMBER of commitment objects, separately from the committed-CPU
# quota. At 1.0 it admits one purchase and no second — a further commitment anywhere in
# us-south1 on this project needs another quota request.
#
# ONE-WAY DOOR. A commitment is irrevocable, non-cancellable and non-transferable.
# Applying this resource spends $2,928 over twelve months whether or not the instance
# it was bought for still exists. Deleting the VM does not stop the charge; deleting
# this resource does not stop the charge either. Treat the apply like a purchase order,
# because it is one — enable_n2d_cud in variables.tf is what makes it a deliberate one.
#
# ONCE THE COMMITMENT EXISTS, flipping the flag back to false does NOT cancel anything. It
# proposes a destroy, which `prevent_destroy` refuses, so the root's applies start failing
# until the flag goes back to true. (Before the purchase this is not so: with nothing in
# state, count 1 -> 0 proposes no destroy and the guard is never reached, which is what
# made disarming while parked free.) That is deliberate: a commitment cannot be
# un-bought, and a config that let you quietly pretend otherwise would be lying. Loud
# failure beats a silent false cancel.
# `gcloud compute commitments` has no delete subcommand at all — the API will not take the
# request either, so the lifecycle guard just fails at plan time instead of mid-apply.
#
# AFTER THE PURCHASE, `enable_n2d_cud = true` must LIVE IN COMMITTED CONFIG for the whole
# twelve months. It is not a momentary buy-once toggle. The trap, which does not require
# anyone to flip anything back: purchase via a one-shot `apply -var enable_n2d_cud=true`
# without committing `true`, and state then holds `[0]` while config says `count = 0` — so
# the next routine apply of this root proposes the destroy and hits `prevent_destroy`.
# Same breakage, reached without `true` ever appearing in git. Commit the flag.
#
# The escape, if this root ever does get stuck: `tofu state rm
# 'google_compute_region_commitment.n2d_validator_1yr[0]'` detaches management. Billing
# continues — correctly, because the obligation is real — and drift detection on a $2,928
# object is lost, so prefer restoring the flag over the state surgery.
#
# ---------------------------------------------------------------------------------
# Sizing — matches the one instance in the estate that runs continuously.
#   OBSERVED: gcloud compute instances list across the ledger estate -> csyn-ldg-validator
#     (n2d-highmem-8, us-south1-a) RUNNING; the five csyn-ldg-dev-* boxes all TERMINATED,
#     and their Compute spend for 202607 was disk $126.59 / vCPU+RAM $0.00, i.e. nothing
#     commitment-eligible outside this project @ 2026-08-11
#   OBSERVED: gcloud compute machine-types describe n2d-highmem-8 --zone=us-south1-a ->
#     guestCpus 8, memoryMb 65536 @ 2026-08-11
#
# The MEMORY amount is 65536 and the unit is the provider's "MB", which follows GCP's own
# memoryMb convention above rather than decimal megabytes. This was verified rather than
# assumed: an off-by-1024 here buys a 64 MB commitment, or a 64 TB one, for a full year.
# 65536 is also a multiple of 256, which the provider schema requires.
#
# ---------------------------------------------------------------------------------
# Why 1 year and not 3, and why resource-based and not flexible.
#   OBSERVED: Cloud Billing Catalog API, service 6F81-5844-456A, us-south1, effective
#     2026-08-11 -> N2D Core on-demand $0.03245236/hr vs $0.02044468 (1yr, 37.00%) vs
#     $0.01460368 (3yr, 55.00%); N2D Ram $0.00434948/GiB-hr vs $0.00273996 (37.00%) vs
#     $0.00195762 (54.99%) @ 2026-08-11
#   OBSERVED: N2D Core+RAM in Dallas, invoice month 202607 -> $387.35 at list with a
#     -$74.05 sustained-use credit already applied, i.e. 19.1% of an N2D ceiling of 20% @ 2026-08-11
#
# CUDs REPLACE sustained-use discounts on covered usage; they do not stack. So the real
# gain is 37% against the 19.1% already being earned for free — about $69/mo, not the
# $143/mo the headline rate suggests. Worth having, but half the apparent prize.
#
# Three-year was rejected on judgment, not arithmetic: its break-even is proportionally
# more forgiving (20 of 36 months against 12-month's 9.3 of 12), but this workload sits on
# a regulated-MSP roadmap with a Confidential-VM rebuild, a possible region move and a
# possible C4/C4D migration all live inside a 36-month window, against two months of
# operating history. Flexible/spend-based was rejected on price: 28%/46% for
# general-purpose, nine points worse on both terms, buying portability that only pays off
# in the one scenario where we would rather not have committed at all.
#
# Not hedged by committing a fraction of the instance. Break-even is 9.35 months at 100%
# and identical at 50% — payoff and loss scale together, so a partial commit shrinks both
# and moves the decision not at all. That is variance reduction, not risk mitigation.
#
# ---------------------------------------------------------------------------------
# What breaks this commitment, for whoever revisits it:
#   - Resize UP within N2D (highmem-8 -> highmem-16): survives. The commitment is a
#     vCPU count and a memory quantity, not a machine type; the excess bills on-demand.
#   - Resize DOWN or to a lower memory ratio: survives but strands the unused portion.
#   - Region move out of us-south1: BREAKS. Resource commitments are region-locked, with
#     no transfer and no refund.
#   - Migration to C4/C4A/C4D: BREAKS COMPLETELY — commitment type is per-family. Note
#     this is a double loss, because the C4 families earn no sustained-use discount either,
#     so that move forfeits the free 19.1% as well as stranding this.
#   - Rebuild onto Confidential VM: the base commitment SURVIVES (the VM still bills
#     against N2D core/RAM SKUs), but the confidential premium is permanently
#     uncommittable — Confidential Computing is a separate billing service carrying zero
#     Commit1Yr/Commit3Yr SKUs. Prefer SEV-SNP over SEV when that happens: cheaper
#     (~$33/mo vs ~$66/mo on this shape) and the stronger attestation model.
#     This does NOT imply a region move. An earlier version of this note said us-south1
#     offers no Confidential VM, so a confidential rebuild would also relocate and thereby
#     break the commitment. That was wrong on both halves.
#       OBSERVED by the r2 gate on #51: three n2d-standard-2 VMs with
#         confidentialInstanceConfig (SEV) reached RUNNING in us-south1-a on this project
#         and were then deleted; post-cleanup the instance list is csyn-ldg-validator
#         alone @ 2026-08-11
#       OBSERVED: gcloud compute zones describe us-south1-a -> availableCpuPlatforms
#         includes AMD Milan, AMD Rome, AMD Turin among 13 entries; Milan is the
#         SEV/SEV-SNP platform N2D runs on @ 2026-08-11
#     So a confidential rebuild stays in region and the commitment survives it.
#
# Verify it landed with the list-price-delta form, NOT by watching the Compute Engine
# total: the commitment fee is a distinct SKU from the usage it covers, so a naive
# month-over-month comparison reads the purchase as a cost increase.
#   SELECT invoice.month, sku.description, SUM(cost_at_list) AS list, SUM(cost) AS net,
#          SUM(cost_at_list - cost) AS savings
#   FROM `<billing-export>.gcp_billing_export_resource_v1_*`
#   WHERE service.description = 'Compute Engine' AND sku.description LIKE '%N2D%Dallas%'
#   GROUP BY 1,2 ORDER BY 1,2;
resource "google_compute_region_commitment" "n2d_validator_1yr" {
  count = var.enable_n2d_cud ? 1 : 0

  project = module.validator.project_id
  name    = "csyn-ldg-n2d-us-south1-1yr"
  # Taken from the validator's own subnet rather than a literal, so the commitment
  # cannot silently end up in a different region from the instance it was bought for.
  # A region-locked commitment pointed at the wrong region is a full-term write-off.
  region   = google_compute_subnetwork.validator.region
  plan     = "TWELVE_MONTH"
  type     = "GENERAL_PURPOSE_N2D"
  category = "MACHINE"

  # Explicitly false rather than relying on the provider default. An irrevocable
  # obligation that silently renews itself is exactly the failure mode worth spelling out.
  auto_renew = false

  resources {
    type   = "VCPU"
    amount = "8"
  }

  resources {
    type   = "MEMORY"
    amount = "65536" # provider "MB", matching GCP's memoryMb for n2d-highmem-8
  }

  lifecycle {
    prevent_destroy = true
  }
}
