# validator-token — the mainnet validator's signing-key secret (spec §3.7 §9.3).
# CMEK-encrypted with the REGIONAL us-south1 key (bootstrap/kms). NO secret VERSION
# here: the token is minted in the air-gapped ceremony (sprint Task 4). This root
# creates ONLY the in-project pieces — the SM service identity, the empty CMEK
# container, and the accessor binding. It does NOT touch the KMS key's IAM.
#
# CROWN-JEWEL SoD (iam-org-policy consult 2026-06-14): the cross-project
# cryptoKeyEncrypterDecrypter grant to the SM service agent is a KMS-IAM write on
# the validator signing-key's CMEK — which the CI apply SA `ledger-apply` must NEVER
# be able to make. Granting it (even key-scoped) setIamPolicy on that key would add
# the GitHub-WIF principalSet to the key's blast radius (a malicious main-merge could
# bind decrypter and exfiltrate the token), and setIamPolicy is not org-deniable so
# there is no backstop. So that grant lives in the AIR-GAPPED CEREMONY, applied by a
# csyn-kms-admins human (who already holds cloudkms.admin to mint the token), as the
# step immediately before the first version-write — see the ceremony runbook below.
# This is safe to omit here because a CMEK secret CONTAINER needs no key grant; the
# key name is stored only as metadata at create — ONLY a secret-VERSION write
# requires the SM agent to hold encrypt/decrypt (verified vs GCP CMEK docs).
#
# CONSVAL1: re-pointed to the HSM key (ledger_validator_secret_key_hsm). The secret
# has 0 versions, so the key swap is a clean metadata change (no re-encryption).
# The SM service agent -> HSM-key encrypt/decrypt binding now lives in bootstrap/kms
# (resource validator_sm_agent_hsm, Pete-applied) — it is NO LONGER a separate
# ceremony gcloud step. So the air-gapped ceremony (sprint Task 8) only WRITES the
# token version once bootstrap/kms is applied:
#   printf '%s' "$VALIDATOR_TOKEN_STANZA" | gcloud secrets versions add validator-token \
#     --project=csyn-ldg-validator-prod --data-file=-

# Materialize the Secret Manager service agent now (google-beta) so the ceremony's
# deterministic agent email (service-<project-number>@gcp-sa-secretmanager) resolves
# without a lazy-create race. ledger-apply can do this — it is in-project. Gated
# behind the API propagation sleep (cs-terraform-overlay rule #7).
resource "google_project_service_identity" "secretmanager" {
  provider   = google-beta
  project    = module.validator.project_id
  service    = "secretmanager.googleapis.com"
  depends_on = [time_sleep.apis]
}

# Empty CMEK secret container. Created WITHOUT the key binding (above): the key name
# is metadata at container-create; only the first version-write (the ceremony) needs
# the SM agent's encrypt/decrypt grant. No version resource lives in this CI root, so
# there is no window where the secret needs the binding but lacks it.
resource "google_secret_manager_secret" "validator_token" {
  project   = module.validator.project_id
  secret_id = "validator-token"

  replication {
    user_managed {
      replicas {
        location = "us-south1" # MUST equal the regional CMEK key's location (string-identical)
        customer_managed_encryption {
          kms_key_name = data.terraform_remote_state.kms.outputs.ledger_validator_secret_key_hsm
        }
      }
    }
  }

  labels = {
    business_line       = "everforge"
    data_classification = "sensitive"
  }
}

# (b) Node/workload SA -> accessor ON THE SECRET (resource-scoped, not project-wide).
# The validator VM (sprint Task 4) runs as this SA and reads the token at boot.
resource "google_secret_manager_secret_iam_member" "node_accessor" {
  project   = google_secret_manager_secret.validator_token.project
  secret_id = google_secret_manager_secret.validator_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${module.validator.workload_sa}"
}
