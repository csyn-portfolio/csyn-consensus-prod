variable "machine_type" {
  type        = string
  default     = "n2d-highmem-8"
  description = "Validator VM machine type. CONSVAL1 mainnet standard = n2d-highmem-8 (8 vCPU / 64 GB, node_size=huge). 'Controlled vertical resize' lever: bump to n2d-highmem-16/32 via a one-line gated PR+apply when Monitoring shows sustained memory/CPU pressure — node_size stays 'huge' across that range (see modules/ledger-node recommended_node_size). Non-confidential by choice: no XRPL req mandates it and the premium is real. NOT because the region lacks support — that reason was falsified 2026-08-11, see validator.tf's header."
}

variable "image_digest" {
  type        = string
  description = "Immutable digest of the xrpld (rippled) image in csyn-ldg-images. Pin by digest, not tag. The mainnet validator runs the SAME digest as svc-rippled-dev — a consensus node must run a reviewed, reproducible image. Default lets CI apply.yml apply without a -var; re-pin after any rebuild (a new build = a new digest even for the same version tag)."
  # PIN: xrpld 3.4.1 — csyn-consensus-infra build-rippled-image.yml run 36250266582
  # (smoke "xrpld version 3.4.1", git d147fccf). Same digest as svc-rippled-dev after
  # that soak. Rollback: sha256:54e618a61ec839d917ad4c1cdc9be024b5679be536e9f75a9b88c2dbe18c3246 (3.4.0).
  # Verify RUNNING — never this comment. Daemon line is jsonPayload.message, not
  # textPayload; boots are rare so --freshness must span the last boot:
  #   gcloud logging read 'logName="projects/csyn-ldg-validator-prod/logs/gcplogs-docker-driver"
  #     AND jsonPayload.message:"Application starting. Version is"' \
  #     --project=csyn-ldg-validator-prod --limit=1 --freshness=30d \
  #     --format="value(timestamp,jsonPayload.message)"
  # Continuous: gcloud storage cat gs://csyn-www-validator1-toml/status.json
  default = "sha256:f37e99dd9101a024fe4da0400ff5a01792462fa9cb02f79e0ca69b49bf2c88f7"
}

variable "sidecar_image_digest" {
  type        = string
  description = "Immutable digest of the xrpl-sidecar image in csyn-ldg-images. Pin by digest, not tag. Default lets CI apply.yml apply without a -var; re-pin after any rebuild (a new build = a new digest even for the same version tag)."
  # Captured from AR after build-sidecar-image.yml (sidecar_version=1.1.0), 2026-06-21:
  #   us-south1-docker.pkg.dev/csyn-ldg-host-dev/csyn-ldg-images/xrpl-sidecar:1.1.0
  #   (1.1.0 adds the UNL freshness metrics; cosign-signed via WIF.)
  default = "sha256:037a5d4d895766743ec1a9fe4a4333b426ac1b669acaaf4e5f505e855ca23700"
}

variable "slack_auth_token" {
  type      = string
  default   = ""
  sensitive = true
  # Bot token from authorizing the "Google Cloud Monitoring" Slack app in the
  # workspace (Monitoring > Alerting > Notification channels > Slack > Add) —
  # interactive, Pete-only. Empty (default) => the Slack channel is NOT created
  # and CI plan stays green. Supply via `-var` or a GH secret at apply time;
  # NEVER commit the token.
  description = "Slack bot token for the Cloud Monitoring Slack notification channel. Empty disables Slack."
}

variable "slack_channel_name" {
  type        = string
  default     = "#consensus-alerts"
  description = "Slack channel that receives validator alerts (used only when slack_auth_token is set)."
}

variable "public_status_image_digest" {
  type        = string
  default     = "sha256:09b8b7be29372ec68675385d68c4c9331227dedd2a482a8f59ef81e1e317c7ab"
  description = "Immutable digest of validator1-status-publisher image in csyn-ldg-images. Empty disables Cloud Run Job + 5m Scheduler (CI plan stays green). Set after: gcloud builds submit --config=tools/cloudbuild.public-status.yaml tools/"
  # 1.0.3 — DEPLOY_PIN_VERSION 3.4.1 (tag 1.0.3). Rollback: sha256:bd978e7f4d6b232f4c20abf547d286295a5746e90924fbbea6604fa9d07e47f1 (1.0.2, 3.4.0 pin).
}

# Purchase gate for the 1-year N2D commitment (commitment.tf). THIS VALUE IS THE ANSWER —
# commitment.tf deliberately does not restate it, because three attempts to mirror it in
# prose went stale within a day each. True means an apply of this root purchases; false
# means an apply cannot.
#
# FALSE, parked 2026-08-11 (Pete). The decision to buy is made and both pre-flight gates
# are cleared; only the apply is outstanding, revisit ~2026-08-25. It was true briefly
# when #50 merged, which left main able to buy the commitment as a side effect of any
# apply of this directory — including the queued dashboard-diff fix. Reverting to false
# is clean while nothing is in state: count goes 1 -> 0, no destroy is proposed, and
# `prevent_destroy` is never reached. That jam only exists after a purchase.
#   OBSERVED: tofu plan with this false -> "Plan: 0 to add, 1 to change, 0 to destroy",
#     the change being the pre-existing dashboard diff; state list -> 0 matches for
#     n2d_validator_1yr @ 2026-08-11
#
# Setting it true again creates an irrevocable twelve-month obligation of roughly $2,928
# that no later change can cancel.
#
# It stays true for the commitment's whole term. It is not a buy-once toggle: with the
# commitment in state, setting this false proposes a destroy that `prevent_destroy`
# refuses, and the root's applies fail until it goes back. See commitment.tf's header.
#
# Both pre-flight gates cleared before this flip:
#   OBSERVED: gcloud compute regions describe us-south1 --project=csyn-ldg-validator-prod
#     -> COMMITMENTS limit=1.0 usage=0.0, raised from the 0.0 observed earlier the same
#     day; control CPUS limit=750.0 confirms the probe reads live values @ 2026-08-11
#   CONFIRMED BY PETE (console, 2026-08-11): billing-account CUD sharing scope is
#     "Billing account", not "Project". Not independently verifiable here — the Cloud
#     Billing API exposes no sharing-scope field (billingAccounts.get returns only
#     currencyCode, displayName, masterBillingAccount, name, open, parent), so this rests
#     on Pete's report rather than an observation of mine.
variable "enable_n2d_cud" {
  type        = bool
  description = "Purchase the 1-year resource-based N2D commitment in us-south1. Irrevocable once applied, and must then remain true for the full term."
  default     = false
}
