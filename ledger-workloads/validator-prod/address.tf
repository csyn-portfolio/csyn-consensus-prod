# Reserved external P2P IP for the mainnet validator (CONSVAL1). Cloud NAT is
# structurally disabled on this VPC, so the external IP is the node's only path to
# the public XRPL network (symmetric P2P 51235). The attach is rejected unless the
# Phase-0 vmExternalIpAccess exception (cloud-syndicate-platform org-foundation,
# ledger_prod_vm_external_ip) is applied first. Keep `description` STABLE — editing
# it forces destroy+recreate of the reserved IP (immutable-field landmine, readiness #8).
resource "google_compute_address" "validator_p2p" {
  project      = module.validator.project_id
  name         = "csyn-ldg-validator-p2p"
  region       = "us-south1"
  address_type = "EXTERNAL"
  description  = "XRPL mainnet validator P2P reserved IP."
}
