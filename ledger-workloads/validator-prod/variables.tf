variable "machine_type" {
  type        = string
  default     = "n2d-highmem-8"
  description = "Validator VM machine type. CONSVAL1 mainnet standard = n2d-highmem-8 (8 vCPU / 64 GB, node_size=huge). 'Controlled vertical resize' lever: bump to n2d-highmem-16/32 via a one-line gated PR+apply when Monitoring shows sustained memory/CPU pressure — node_size stays 'huge' across that range (see modules/ledger-node recommended_node_size). Non-confidential by design: us-south1 offers no Confidential VM and no XRPL req mandates it."
}

variable "image_digest" {
  type        = string
  description = "Immutable digest of the xrpld (rippled) image in csyn-ldg-images. Pin by digest, not tag. The mainnet validator runs the SAME dev-vetted build as svc-rippled-dev (xrpld 3.2.1) — a consensus node must run a reviewed, reproducible image. Default lets CI apply.yml apply without a -var; re-pin after any rebuild (a new build = a new digest even for the same version tag)."
  # Captured from build-rippled-image.yml run 30714125224 (csyn-consensus-infra),
  # 2026-08-01: tag 3.2.1 -> sha256:e664d4c5… (smoke: "xrpld version 3.2.1").
  # Full image rebuild on unpinned debian:12-slim + xrpld=3.2.1-1 (manifest-propagation
  # hotfix XRPLF/rippled#7925) — not a binary-only patch delta vs 3.2.0 image.
  # Rollback digest (prior pin): sha256:ba7a6ddabb23d785868fd88277950c10db131be3e725d27e8cb1e254b023ed39 (3.2.0).
  # SAME digest as svc-rippled-dev (dev soak first — dual-gate C3).
  default = "sha256:e664d4c5f6bb0e5538f53cb1ad6c6cd5560b6f550141f651754fe1cf563a98c8"
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
