# Validator firewall on its OWN VPC (spec §9.3). Every rule is SA-scoped to the
# dedicated workload SA (terrashark blast-radius control). Symmetric XRPL P2P
# (51235) is public BOTH directions — no LB / Cloud Armor can front symmetric
# peering, so the accepted DDoS posture is the symmetric peer protocol itself
# (spec §9.3). Egress is locked to P2P + the restricted VIP; everything else hits
# the VPC-wide deny floor.
locals {
  validator_sa   = module.validator.workload_sa
  xrpl_p2p       = "51235"
  restricted_vip = "199.36.153.4/30" # dns-restricted.tf maps *.googleapis.com here
}

# --- INGRESS ---
# XRPL mainnet P2P — public (mainnet peers reach the validator on its reserved EIP).
resource "google_compute_firewall" "p2p_in" {
  project                 = module.validator.project_id
  name                    = "csyn-ldg-validator-p2p-in"
  network                 = google_compute_network.vpc.name
  direction               = "INGRESS"
  priority                = 1000
  description             = "XRPL mainnet P2P peer protocol (public, symmetric)."
  source_ranges           = ["0.0.0.0/0"]
  target_service_accounts = [local.validator_sa]
  allow {
    protocol = "tcp"
    ports    = [local.xrpl_p2p]
  }
}
# Admin RPC (5005) + WS-admin are localhost-only by design — no allow rule, so
# GCP's implied-deny ingress (@65535) blocks them off-box. The absence IS the
# control; no separate ingress deny-floor is needed (ingress is implied-deny).

# IAP-tunnel SSH (CONSVAL1 Task 10) — the ONLY operator path to the localhost-only
# admin RPC (5005) to confirm server_state:proposing; rippled logs do NOT reach Cloud
# Logging (no gcplogs driver). SA-scoped ingress from Google's IAP TCP-forwarding
# range only — no public SSH; IAP brokers the connection. Paired with the
# instance-scoped iap.tunnelResourceAccessor + compute.osLogin grants in iam.tf. OS
# Login is enforced org-wide (compute.requireOsLogin), so guest-side key lookups go
# through the metadata server (link-local, always-allowed) — no egress dependency,
# and metadata-key SSH is superseded.
resource "google_compute_firewall" "iap_ssh_in" {
  project                 = module.validator.project_id
  name                    = "csyn-ldg-validator-iap-ssh-in"
  network                 = google_compute_network.vpc.name
  direction               = "INGRESS"
  priority                = 1000
  description             = "IAP-tunneled SSH for admin-RPC verification; IAP range only, SA-scoped."
  source_ranges           = ["35.235.240.0/20"]
  target_service_accounts = [local.validator_sa]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# --- EGRESS named allows (VPC-wide deny floor below) ---
# Outbound P2P to mainnet peers (arbitrary internet — the nature of P2P).
resource "google_compute_firewall" "egress_p2p" {
  project                 = module.validator.project_id
  name                    = "csyn-ldg-validator-egress-p2p"
  network                 = google_compute_network.vpc.name
  direction               = "EGRESS"
  priority                = 1000
  description             = "Outbound XRPL mainnet P2P peer connections."
  destination_ranges      = ["0.0.0.0/0"]
  target_service_accounts = [local.validator_sa]
  allow {
    protocol = "tcp"
    ports    = [local.xrpl_p2p]
  }
}

# Google APIs via the restricted VIP only (PGA; Secret Manager / KMS / Monitoring /
# Logging). Paired with dns-restricted.tf — without that zone this allow is inert.
resource "google_compute_firewall" "egress_restricted_vip" {
  project                 = module.validator.project_id
  name                    = "csyn-ldg-validator-egress-vip"
  network                 = google_compute_network.vpc.name
  direction               = "EGRESS"
  priority                = 1000
  description             = "Egress to Google restricted VIP (443) — API access without NAT."
  destination_ranges      = [local.restricted_vip]
  target_service_accounts = [local.validator_sa]
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

# VPC-wide EGRESS DENY floor @65534 (just above GCP's implied-allow @65535) —
# mirrors host-dev/firewall.tf (D2). UN-scoped (no target_service_accounts): a
# true network floor, not a per-identity deny, so any instance on this VPC that is
# NOT the validator SA (a debug box, a mis-tagged VM) has no egress at all. The
# named allows @1000 punch through for exactly the validator's two flows. GCP
# always-allows DNS/DHCP/metadata to 169.254.169.254 regardless, so name
# resolution to the restricted VIP still works.
resource "google_compute_firewall" "egress_deny_floor" {
  project            = module.validator.project_id
  name               = "csyn-ldg-validator-egress-deny-floor"
  network            = google_compute_network.vpc.name
  direction          = "EGRESS"
  priority           = 65534
  description        = "VPC-wide default-deny egress floor; per-SA named allows @1000 override it."
  destination_ranges = ["0.0.0.0/0"]
  deny {
    protocol = "all"
  }
  depends_on = [time_sleep.apis]
}
