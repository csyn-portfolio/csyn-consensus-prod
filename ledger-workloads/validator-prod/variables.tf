variable "machine_type" {
  type        = string
  default     = "n2d-highmem-8"
  description = "Validator VM machine type. CONSVAL1 mainnet standard = n2d-highmem-8 (8 vCPU / 64 GB, node_size=huge). 'Controlled vertical resize' lever: bump to n2d-highmem-16/32 via a one-line gated PR+apply when Monitoring shows sustained memory/CPU pressure — node_size stays 'huge' across that range (see modules/ledger-node recommended_node_size). Non-confidential by design: us-south1 offers no Confidential VM and no XRPL req mandates it."
}

variable "image_digest" {
  type        = string
  description = "Immutable digest of the xrpld (rippled) image in csyn-ldg-images. Pin by digest, not tag. The mainnet validator runs the SAME dev-vetted build as svc-rippled-dev (xrpld 3.3.0) — a consensus node must run a reviewed, reproducible image. Default lets CI apply.yml apply without a -var; re-pin after any rebuild (a new build = a new digest even for the same version tag)."
  # PIN: xrpld 3.3.0 — build 31232108548, digest 2f984bdb… (smoke "xrpld version 3.3.0").
  # SAME digest as svc-rippled-dev. Prod cutover 2026-08-08T02:20Z (boot log "Application
  # starting. Version is 3.3.0"); soak window ≤14d from cutover. Verify what is RUNNING
  # via Cloud Logging (Application start line) or the sidecar gauges — never this comment.
  # Rollback: sha256:e664d4c5f6bb0e5538f53cb1ad6c6cd5560b6f550141f651754fe1cf563a98c8 (3.2.1).
  # Snapshots at cutover: validator-pre-330-{boot,data}-20260808-0218 (keep-latest policy).
  default = "sha256:2f984bdbff9c6848b740c79eee972322a0be3f1a1346f7f0745fe94a81cd916b"
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
  default     = ""
  description = "Immutable digest of validator1-status-publisher image in csyn-ldg-images. Empty disables Cloud Run Job + 5m Scheduler (CI plan stays green). Set after: gcloud builds submit --config=tools/cloudbuild.public-status.yaml tools/"
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
