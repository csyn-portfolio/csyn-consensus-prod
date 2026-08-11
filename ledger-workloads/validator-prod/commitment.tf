# Committed use discount — 1 year, resource-based, N2D, us-south1.
#
# GATED OFF BY DEFAULT. `enable_n2d_cud` defaults to false, so merging this file buys
# nothing. Flipping it to true is a separate, deliberate change — which is the point:
# this root is dispatched by apply.yml with a `configs` input, so without the flag anyone
# applying ledger-workloads/validator-prod for an unrelated reason would execute the
# purchase. A comment saying "human apply only" is not a control; a default-false count is.
#
# PRE-FLIGHT, and this blocks: the COMMITMENTS regional quota must be >= 1 before the
# purchase can succeed at all.
#   OBSERVED: gcloud compute regions describe us-south1 --project=csyn-ldg-validator-prod
#     -> COMMITMENTS limit=0.0 usage=0.0, while COMMITTED_N2D_CPUS limit=9.22e18 and 106
#     other quotas in the same response are non-zero @ 2026-08-11
# COMMITMENTS caps the NUMBER of commitment objects, separately from the committed-CPU
# quota, and it is zero on this project. Request an increase to >= 1 in us-south1 first.
# Fail-closed: an apply before that errors out and spends nothing.
#
# ONE-WAY DOOR. A commitment is irrevocable, non-cancellable and non-transferable.
# Applying this resource spends $2,928 over twelve months whether or not the instance
# it was bought for still exists. Deleting the VM does not stop the charge; deleting
# this resource does not stop the charge either. Treat the apply like a purchase order,
# because it is one — the flag above is what makes it a deliberate one.
#
# Flipping the flag back to false does NOT cancel anything. It proposes a destroy, which
# `prevent_destroy` refuses, so the root's applies start failing until the flag goes back
# to true. That is deliberate: a commitment cannot be un-bought, and a config that let you
# quietly pretend otherwise would be lying. Loud failure beats a silent false cancel.
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
#     Note also validator.tf's finding that us-south1 offers no Confidential VM at all,
#     so that rebuild is a region move as well — and a region move breaks this.
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
