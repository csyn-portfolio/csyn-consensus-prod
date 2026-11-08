# Validator cost by US region: no CUD, 1-year and 3-year CUDs

**Date:** 2026-11-07 · **Prices:** Cloud Billing Catalog, effective 2026-11-07T08:00Z · **Usage:** billing export, `csyn-ldg-validator-prod`, invoice month 202610
**Model:** [`tools/finops/us_region_model.py`](../../tools/finops/us_region_model.py) (79 SKUs frozen in `tools/finops/catalog-snapshot-2026-11-07-us.json`)
**Status:** analysis only. Nothing is purchased, applied or moved. Whether a commitment exists is a command, not this page: `gcloud compute commitments list --project=csyn-ldg-validator-prod`.

## Question

Would the mainnet validator be cheaper in another US region, and by how much, with no committed use discount (CUD), a 1-year CUD and a 3-year CUD?

Shape held constant: n2d-highmem-8 (8 vCPU / 64 GiB), Shielded VM, 20 + 150 GiB pd-ssd, October's billed usage.

## Answer

All-in $/mo, ex-tax. "No CUD" is on-demand with the 20% sustained-use discount (SUD), which October earned in full.

| Region | No CUD | 1-yr resource CUD | 3-yr resource CUD | vs Dallas (none / 1y / 3y) |
|---|---:|---:|---:|---:|
| **us-central1 Iowa, us-east1 South Carolina, us-west1 Oregon** | **713** | **656** | **597** | **−53 / −43 / −32** |
| us-east5 Columbus | 713 | 657 | 597 | −53 / −43 / −32 |
| us-east4 Virginia, us-west4 Las Vegas | 750 | 674 | 610 | −16 / −25 / −19 |
| **us-south1 Dallas (today)** | **766** | **699** | **629** | 0 / 0 / 0 |
| us-west2 Los Angeles, us-west3 Salt Lake City | 772–773 | 704–705 | 632–633 | +6 / +5 / +4 |

- Dallas is the third most expensive of the nine US regions this project can use. N2D vCPU and RAM cost 15% less in the cheapest tier ($332.82 against $392.73 a month at list), and pd-ssd costs $0.17 against $0.2006 per GiB-month.
- Moving to the cheapest tier saves $32–53/mo, or $386–638 a year (Virginia or Las Vegas: $16–25/mo). The saving is small because 47% of the bill is internet egress (3,064 GiB in October, $357), and each destination's egress rate is the same from every US region. To the Americas that is $0.12, then $0.11 above 1 TiB, then $0.08 above 10 TiB; EMEA and APAC drop to $0.085 above 10 TiB, and Australia is $0.19 / $0.18 / $0.15.
- The commitment is worth more than the move. In Dallas a 1-year CUD saves $67/mo and a 3-year CUD saves $137/mo.
- Iowa on a 3-year resource CUD is $597/mo against $766 today, −$170/mo.

## Compute only, $/mo

| Region | On-demand list | + SUD | 1-yr resource | 3-yr resource | 1-yr flexible | 3-yr flexible |
|---|---:|---:|---:|---:|---:|---:|
| us-central1 / us-east1 / us-west1 / us-east5 | 332.82 | 266.26 | 209.67 | 149.78 | 239.63 | 179.72 |
| us-east4 / us-west4 | 374.83 | 299.87 | 224.37 | 160.26 | 269.88 | 202.41 |
| us-south1 Dallas | 392.73 | 314.18 | 247.41 | 176.75 | 282.77 | 212.07 |
| us-west2 / us-west3 | 399.75 | 319.80 | 251.84 | 179.88 | 287.82 | 215.86 |

- Resource CUDs are 37% (1-yr) and 55% (3-yr) off list in seven of the nine regions. In us-east4 Virginia and us-west4 Las Vegas they are 40% and 57%. Flexible CUDs are 28% and 46% off everywhere (SKUs `F61D-4D51-AAFC`, `6723-40D7-8BDC`).
- A CUD replaces the SUD on the usage it covers; the two do not add. The real gain over no CUD is the CUD rate against the 20% already earned.
- Break-even against no CUD is 9.4 of 12 months (1-yr) and 20.3 of 36 months (3-yr) in the 37% / 55% regions, and 9.0 and 19.2 months in Virginia and Las Vegas.
- Obligation: Dallas $2,969 (1-yr) or $6,363 (3-yr). Iowa $2,516 or $5,392. Neither can be cancelled.

## Before choosing

1. **Pick the region before buying a resource CUD.** A resource CUD is locked to one region and the N2D family, with no transfer or refund. A flexible CUD follows the spend to any region but gives 9 points less discount (12 in Virginia and Las Vegas). The planned 1-year Dallas commitment (`commitment.tf`, gated by `enable_n2d_cud`) was never bought: `gcloud compute commitments list` returned `Listed 0 items` on 2026-11-07.
2. **What a move involves.** In-region resources are rebuilt in the new region: subnet and firewall, reserved P2P address (the IP changes; peers rediscover it), a new regional HSM keyring and keys in `bootstrap/kms` (`cloud-syndicate-platform`, Pete-apply), the `validator-token` secret's regional replica re-encrypted under the new key, CMEK disks restored from snapshot under the new key, and a clock-safe recreate per `docs/runbooks/validator-recreate.md`. Snapshots are stored in the US multi-region, so the ledger data carries over. Images can stay in the us-south1 Artifact Registry (cross-region pull) or be copied.
3. **What does not block a move.** `gcp.resourceLocations` on `ledger/prod/validators` inherits `in:us-locations`. n2d-highmem-8 and Cloud HSM are offered in all nine regions (`gcloud compute machine-types list --filter=name=n2d-highmem-8`, `gcloud kms locations list`, 2026-11-07). us-south1 was chosen in CONSVAL1 to sit with the rest of the ledger estate, not for an XRPL reason.
4. **Commitment quota.** The `COMMITMENTS` quota is per region. A new region needs its own quota request before a resource CUD can be bought.
5. **Not offered here.** us-west8 (Phoenix) carries SKUs at the cheapest tier but is not in `gcloud compute regions list` for this project.

## Watch: egress is rising

The first six days of November billed 881.8 GiB of egress over 149.5 VM-hours. At that rate the month comes to about 4,300 GiB and $517, against $357 in October. That is an inference from a partial month, and the export can lag. Egress costs the same in every US region, so the comparison above does not change, but the all-in totals would rise by the same amount in every column.

## Reproduce

```bash
python3 -I tools/finops/us_region_model.py   # tables above; exits 1 if a SKU is missing
                                             # or Dallas drifts >2% from October billed
```

The self-checks were tested by breaking them on purpose: removing SKU `29DE-E9FE-7872` (N2D core, Dallas) from the snapshot gave exit 1 with `KeyError`, and raising billed October egress by 10% gave exit 1 with `egress model drifted from billed actuals` (9.09%).

Billed actuals:

```sql
SELECT CASE WHEN sku.description LIKE "N2D%" THEN "compute"
            WHEN sku.description LIKE "Network Internet Data Transfer%" THEN "egress"
            WHEN sku.description LIKE "%PD%" THEN "disk"
            WHEN service.description = "Invoice" THEN "tax" ELSE "other" END k,
       ROUND(SUM(cost), 2) list_cost,
       ROUND(SUM(cost + (SELECT IFNULL(SUM(x.amount), 0) FROM UNNEST(credits) x)), 2) net
FROM `csyn-billing.csyn_billing_export.gcp_billing_export_resource_v1_01F3D3_6ED75A_789253`
WHERE project.id = "csyn-ldg-validator-prod" AND invoice.month = "202610"
GROUP BY 1 ORDER BY 1
-- 2026-11-07: compute 401.37 list / 321.00 net · disk 34.86 · egress 357.24 · other 57.76 net · tax 50.85
```

Related: the 3-year Dallas + Japan + Germany analysis is on branch `docs/finops-cud-3yr-jp-de`, which is local only and not on `main`.
