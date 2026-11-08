#!/usr/bin/env python3
"""Validator cost in every US region this project can use, with no CUD, 1-yr and 3-yr CUDs.

Shape: n2d-highmem-8 (8 vCPU / 64 GiB), 20 + 150 GiB pd-ssd, the CONSVAL1 validator.
Prices: catalog-snapshot-2026-11-07-us.json (Cloud Billing Catalog API, service
6F81-5844-456A, pulled 2026-11-07). Usage: billing export for csyn-ldg-validator-prod,
invoice month 202610; the query is in docs/finops/2026-11-07-us-region-cud.md.

    python3 -I tools/finops/us_region_model.py

Exits non-zero if a SKU is missing from the snapshot, or if the Dallas model drifts more
than 2% from what October actually billed for compute (at list), egress or pd-ssd.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CAT = {s["skuId"]: s for s in json.load(open(os.path.join(HERE, "catalog-snapshot-2026-11-07-us.json")))}


def tiers(sku):
    t = CAT[sku]["pricingInfo"][0]["pricingExpression"]["tieredRates"]
    return [(float(x["startUsageAmount"]), int(x["unitPrice"].get("units", 0)) + x["unitPrice"].get("nanos", 0) / 1e9) for x in t]


def unit(sku):
    t = tiers(sku)
    assert len(t) == 1, f"{sku} is tiered; use tiered()"
    return t[0][1]


def tiered(sku, qty):
    t, cost = tiers(sku), 0.0
    for i, (start, price) in enumerate(t):
        end = t[i + 1][0] if i + 1 < len(t) else float("inf")
        if qty > start:
            cost += (min(qty, end) - start) * price
    return cost


H = 730                       # GCP monthly-hours convention
VCPU, RAM_GIB, DISK_GIB = 8, 64, 170
SUD = 0.20                    # N2D full-month sustained-use discount; Oct billed 20.0% (80.37 on 401.37)
FLEX1_SKU, FLEX3_SKU = "F61D-4D51-AAFC", "6723-40D7-8BDC"  # $ per $0.01 of on-demand hourly spend

# Billed, csyn-ldg-validator-prod, invoice 202610 (net of credits, ex-tax).
OCT = dict(vm_h=5965.9 / 8, compute_list=401.37, egress=357.24, pd=34.21, pd_gib=170.6)
EGRESS_GIB = {"Americas": 2198.7, "EMEA": 763.8, "Apac(Excluding Korea and Indonesia)": 79.2, "Australia": 22.8}
SNAP = 0.65                   # "Storage PD Snapshot in US": multi-region, same wherever the VM runs
OTHER = 57.76 + 2.20          # logging, flow logs, Cloud Run publisher, DNS, SM (Oct billed) + csyn-kms HSM keys
# OTHER and SNAP do not depend on the VM's region. Egress rates are identical across US regions.

AM = dict(core="A03E-E620-7389", ram="5535-6D2D-4B50", c1="46C4-6958-048B", r1="02B2-13AB-C4A0",
          c3="4AF8-4541-4752", r3="3080-B456-59FC", pd="B188-61DD-52E4",
          eg={"Americas": "F274-1692-F213", "EMEA": "DFA5-B5C6-36D6", "Apac(Excluding Korea and Indonesia)": "378D-6896-1041", "Australia": "FDBC-6E3B-D4D8"})
REGIONS = {
    "us-central1 (Iowa)": AM, "us-east1 (South Carolina)": AM, "us-west1 (Oregon)": AM,
    "us-east5 (Columbus)": dict(core="2C08-0DED-36F3", ram="5682-8AD5-97D9", c1="85E4-6F60-F26B", r1="C1F7-3E62-74BB",
        c3="E721-EE8C-D29D", r3="1F87-1D2D-DFB2", pd="0E37-3202-AA60",
        eg={"Americas": "2623-976D-48E0", "EMEA": "4128-2E60-87E4", "Apac(Excluding Korea and Indonesia)": "0F89-58FD-2FD3", "Australia": "F268-85E6-2825"}),
    "us-east4 (Virginia)": dict(core="809C-1E3B-306E", ram="D293-6255-369A", c1="ECB4-77C6-03FA", r1="49C0-5C14-F72A",
        c3="D144-676A-CEE8", r3="0B02-AF95-B42A", pd="75B0-B95E-76A8",
        eg={"Americas": "1A51-8906-72EB", "EMEA": "B290-3774-A052", "Apac(Excluding Korea and Indonesia)": "9BCB-C987-5DAB", "Australia": "E416-CA19-047B"}),
    "us-west4 (Las Vegas)": dict(core="0E8D-9FEF-852D", ram="ABD2-309F-B86A", c1="6B44-88D5-C8C4", r1="1F6A-F642-D6E3",
        c3="C357-5123-3B4E", r3="E36E-BAA8-0EB4", pd="CF9E-3EFB-D09B",
        eg={"Americas": "706B-9D5D-1176", "EMEA": "7226-E677-056F", "Apac(Excluding Korea and Indonesia)": "8EA7-73CA-4618", "Australia": "3170-81B7-609A"}),
    "us-south1 (Dallas, today)": dict(core="29DE-E9FE-7872", ram="296B-A47C-3667", c1="04EB-F366-1883", r1="7056-1AC9-F0A4",
        c3="EB5B-800B-B4E5", r3="D9C6-16DF-4821", pd="DBD1-66F6-9AFE",
        eg={"Americas": "E6EE-8CA6-6FA0", "EMEA": "6122-A498-C2E4", "Apac(Excluding Korea and Indonesia)": "E0FE-30A7-9D30", "Australia": "96D6-65DA-927E"}),
    "us-west2 (Los Angeles)": dict(core="2540-FD54-92D3", ram="1FEE-CE8E-2D35", c1="6E35-6E9F-5FAA", r1="5542-CBC0-D2BE",
        c3="919D-B2CA-C1AB", r3="8C8F-00CB-59FE", pd="0589-AA00-68BD",
        eg={"Americas": "EB55-92E0-41A2", "EMEA": "9217-116C-69FF", "Apac(Excluding Korea and Indonesia)": "C018-EF25-367F", "Australia": "6705-13F0-2D9B"}),
    "us-west3 (Salt Lake City)": dict(core="011F-F649-4A0D", ram="98E9-BA44-DDD2", c1="E028-0D63-94A1", r1="0AF5-CCCB-4E2C",
        c3="9217-6E6E-FB9B", r3="6027-9245-D64F", pd="6A0C-F783-3754",
        eg={"Americas": "F961-DDD5-6A3A", "EMEA": "9778-07FB-B37C", "Apac(Excluding Korea and Indonesia)": "9DB8-BE55-4503", "Australia": "67B5-967D-4144"}),
}
DALLAS = "us-south1 (Dallas, today)"


def mix(r, core, ram):
    return VCPU * H * unit(r[core]) + RAM_GIB * H * unit(r[ram])


def node(r):
    od = mix(r, "core", "ram")
    rest = DISK_GIB * unit(r["pd"]) + SNAP + sum(tiered(r["eg"][k], g) for k, g in EGRESS_GIB.items()) + OTHER
    return dict(od_list=od, none=od * (1 - SUD), cud1=mix(r, "c1", "r1"), cud3=mix(r, "c3", "r3"),
                flex1=od * unit(FLEX1_SKU) / 0.01, flex3=od * unit(FLEX3_SKU) / 0.01,
                pd=DISK_GIB * unit(r["pd"]), egress=sum(tiered(r["eg"][k], g) for k, g in EGRESS_GIB.items()), rest=rest)


def main():
    nodes = {n: node(r) for n, r in REGIONS.items()}
    print(f"resolved {len(CAT)} catalog SKUs across {len(REGIONS)} regions")
    d = nodes[DALLAS]
    checks = [("compute at list", d["od_list"] * OCT["vm_h"] / H, OCT["compute_list"]),
              ("egress", d["egress"], OCT["egress"]),
              ("pd-ssd", d["pd"] * OCT["pd_gib"] / DISK_GIB, OCT["pd"])]
    for label, model, billed in checks:
        drift = abs(model - billed) / billed
        print(f"self-check {label}: model ${model:.2f} vs Oct billed ${billed:.2f} ({drift:.2%})")
        if drift > 0.02:
            sys.exit(f"{label} model drifted from billed actuals")
    print(f"\n{'$/mo':28}{'OD list':>9}{'none':>9}{'1y res':>9}{'3y res':>9}{'1y flex':>9}{'3y flex':>9}{'pd-ssd':>8}{'egress':>8}"
          f"{'ALL none':>10}{'ALL 1y':>9}{'ALL 3y':>9}{'Δ none':>9}{'Δ 1y':>8}{'Δ 3y':>8}")
    for n, v in sorted(nodes.items(), key=lambda kv: kv[1]["none"] + kv[1]["rest"]):
        a = [v[k] + v["rest"] for k in ("none", "cud1", "cud3")]
        b = [d[k] + d["rest"] for k in ("none", "cud1", "cud3")]
        print(f"{n:28}{v['od_list']:9.2f}{v['none']:9.2f}{v['cud1']:9.2f}{v['cud3']:9.2f}{v['flex1']:9.2f}{v['flex3']:9.2f}"
              f"{v['pd']:8.2f}{v['egress']:8.2f}{a[0]:10.2f}{a[1]:9.2f}{a[2]:9.2f}" + "".join(f"{x - y:+9.2f}" if i == 0 else f"{x - y:+8.2f}" for i, (x, y) in enumerate(zip(a, b))))
    print()
    for n in ("us-central1 (Iowa)", DALLAS):
        v = nodes[n]
        print(f"{n:28} break-even 1y {12 * v['cud1'] / v['none']:.1f} of 12 mo, 3y {36 * v['cud3'] / v['none']:.1f} of 36 mo;"
              f" obligation 1y ${12 * v['cud1']:,.0f}, 3y ${36 * v['cud3']:,.0f}")


if __name__ == "__main__":
    main()
