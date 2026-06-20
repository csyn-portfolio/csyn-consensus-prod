output "project_id" {
  description = "csyn-ldg-validator-prod — the standalone mainnet validator project."
  value       = module.validator.project_id
}

output "workload_sa" {
  description = "Dedicated workload SA (CS baseline #4) — the validator VM's runtime identity (sprint Task 4), firewall target, and secret accessor."
  value       = module.validator.workload_sa
}

output "validator_vpc" {
  description = "Self-link of the validator's standalone VPC (attached to no host)."
  value       = google_compute_network.vpc.id
}

output "validator_token_secret" {
  description = "Resource ID of the (empty) validator-token secret — the air-gapped ceremony writes the first version here (sprint Task 4)."
  value       = google_secret_manager_secret.validator_token.id
}

output "validator_p2p_ip" {
  description = "Reserved external P2P IP for the validator VM (sprint Task 9) and the validator.cloudsyndicate.io domain record (Task 11)."
  value       = google_compute_address.validator_p2p.address
}
