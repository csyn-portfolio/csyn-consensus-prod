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
# only — no Cloud NAT, no external IP on the API path (dns-restricted.tf).
#
# VPC Flow Logs OFF (Pete, 2026-11-16), via a generation filter that matches
# nothing. They ran at 5 s / 1.0 sampling / all metadata for SOC-2 / incident
# forensics (spec §9.3) and cost about $22/mo
# (~45 GiB/mo billed twice: Networking Telemetry + Vended Logs Storage). Nothing
# read them: no alert, metric, sink or policy check. Accepted trade-off: no
# per-flow record for network forensics; firewall rules and the egress deny-floor
# still enforce. Re-enable by restoring the previous log_config (git history).
resource "google_compute_subnetwork" "validator" {
  project                  = module.validator.project_id
  name                     = "csyn-ldg-validator-us-south1"
  region                   = "us-south1"
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.60.0.0/28"
  private_ip_google_access = true

  # Generate nothing. Not enable_flow_logs = false: on this provider that field is
  # force-new and the plan replaced the subnet under the running validator. Not
  # omitting log_config: the live config stays (no diff). filter_expr is the
  # generation filter, so "false" means no records and no Networking Telemetry
  # charge; the other three settings are the cheapest values if it is ever relaxed.
  log_config {
    filter_expr          = "false"
    aggregation_interval = "INTERVAL_15_MIN"
    flow_sampling        = 0.5
    metadata             = "EXCLUDE_ALL_METADATA"
  }
}
