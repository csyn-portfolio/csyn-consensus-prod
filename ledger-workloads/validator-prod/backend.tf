# ledger-workloads/validator-prod — normal (CI-applicable) root.
# State prefix has NO bootstrap/ marker: the mainnet validator is workload infra,
# not org-foundation, so it applies from CI via the folder-scoped ledger-apply SA
# (Path 2), same routing as the Stage 3 service roots (apply.yml
# startsWith(matrix.config, 'ledger-workloads/') => ledger-apply). See spec §3.8 / §6.
terraform {
  backend "gcs" {
    bucket = "csyn-tf-state"
    prefix = "ledger-workloads/validator-prod"
  }
}
