variable "machine_type" {
  type        = string
  default     = "n2d-highmem-8"
  description = "Validator VM machine type. CONSVAL1 mainnet standard = n2d-highmem-8 (8 vCPU / 64 GB, node_size=huge). 'Controlled vertical resize' lever: bump to n2d-highmem-16/32 via a one-line gated PR+apply when Monitoring shows sustained memory/CPU pressure — node_size stays 'huge' across that range (see modules/ledger-node recommended_node_size). Non-confidential by design: us-south1 offers no Confidential VM and no XRPL req mandates it."
}

variable "image_digest" {
  type        = string
  description = "Immutable digest of the xrpld (rippled) image in csyn-ldg-images. Pin by digest, not tag. The mainnet validator runs the SAME dev-vetted build as svc-rippled-dev (xrpld 3.2.0) — a consensus node must run a reviewed, reproducible image. Default lets CI apply.yml apply without a -var; re-pin after any rebuild (a new build = a new digest even for the same version tag)."
  # Captured live from AR (gcloud artifacts docker images list
  # us-south1-docker.pkg.dev/csyn-ldg-host-dev/csyn-ldg-images/rippled) 2026-06-18:
  # tag 3.2.0 -> sha256:ba7a6dda… (matches svc-rippled-dev's current pin).
  default = "sha256:ba7a6ddabb23d785868fd88277950c10db131be3e725d27e8cb1e254b023ed39"
}

variable "sidecar_image_digest" {
  type        = string
  description = "Digest (sha256:...) of the xrpl-sidecar image to pin on the validator VM."
  # No default (unlike image_digest): the first sidecar deploy requires an explicit
  # pin; add the built digest after the first build-sidecar-image.yml run.
}
