# Standalone minimal VPC for the mainnet validator (spec §9.3). Own VPC, attached
# to NO host (network_role=standalone) — the validator is isolated from the testnet
# Shared VPC by design. REGIONAL routing; us-south1 (Consensus first region, §3.3).
resource "google_compute_network" "vpc" {
  project                 = module.validator.project_id
  name                    = "csyn-ldg-validator-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  depends_on              = [time_sleep.apis]
}

# Validator subnet. /28 — one validator instance + headroom. PGA on: Google API
# egress (Secret Manager / KMS / Monitoring / Logging) goes via the restricted VIP
# only — no Cloud NAT, no external IP on the API path (dns-restricted.tf). Flow
# logs at FULL 1.0 sampling: a mainnet signing node warrants complete network
# visibility for SOC-2 / incident forensics (vs 0.5 on the testnet, spec §9.3).
resource "google_compute_subnetwork" "validator" {
  project                  = module.validator.project_id
  name                     = "csyn-ldg-validator-us-south1"
  region                   = "us-south1"
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.60.0.0/28"
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 1.0
    metadata             = "INCLUDE_ALL_METADATA"
  }
}
