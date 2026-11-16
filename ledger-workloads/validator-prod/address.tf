# Reserved external P2P IP for the mainnet validator (CONSVAL1). Cloud NAT is
# structurally disabled on this VPC, so the external IP is the node's only path to
# the public XRPL network (symmetric P2P 51235). The attach is rejected unless the
# Phase-0 vmExternalIpAccess exception (cloud-syndicate-platform org-foundation,
# ledger_prod_vm_external_ip) is applied first. Keep `description` STABLE — editing
# it forces destroy+recreate of the reserved IP (immutable-field landmine, readiness #8).
#
# Premium Tier, 34.174.33.70, attached today. The Standard Tier move below
# (Pete, 2026-11-16) is two PRs: this one reserves the Standard address; the next
# swaps validator.tf to it. Keep this address reserved after the swap so a
# rollback gets the same IP back.
resource "google_compute_address" "validator_p2p" {
  project      = module.validator.project_id
  name         = "csyn-ldg-validator-p2p"
  region       = "us-south1"
  address_type = "EXTERNAL"
  description  = "XRPL mainnet validator P2P reserved IP."
}

# Standard Tier P2P IP (Pete, 2026-11-16): internet egress is about half the
# validator bill, and Standard prices it per source region ($0.085/GiB after 200
# free GiB/month from Dallas) instead of per destination ($0.11-0.19/GiB), about
# $139/mo less at the 2026-11-09..15 volume. An address cannot change tier, so
# this is a new IP; validator.tf attaches it with a matching access-config tier
# in the follow-up PR.
# Same immutable-description landmine as above.
resource "google_compute_address" "validator_p2p_std" {
  project      = module.validator.project_id
  name         = "csyn-ldg-validator-p2p-std"
  region       = "us-south1"
  address_type = "EXTERNAL"
  network_tier = "STANDARD"
  description  = "XRPL mainnet validator P2P reserved IP, Standard Tier."
}
