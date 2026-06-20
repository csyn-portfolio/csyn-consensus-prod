# One-way dependency: bootstrap -> this workload root (never the reverse).
# org_foundation supplies the ledger/PROD folder ID; kms supplies the REGIONAL
# us-south1 CMEK key for the validator-token secret (re-pinned regionally — see
# bootstrap/kms; the multi-region 'us' key cannot encrypt a regional SM replica).
data "terraform_remote_state" "org_foundation" {
  backend = "gcs"
  config = {
    bucket = "csyn-tf-state"
    prefix = "bootstrap/org-foundation"
  }
}

data "terraform_remote_state" "kms" {
  backend = "gcs"
  config = {
    bucket = "csyn-tf-state"
    prefix = "bootstrap/kms"
  }
}
