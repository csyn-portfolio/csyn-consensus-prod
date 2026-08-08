# csyn-ldg-validator-prod — standalone mainnet XRPL validator project
# (spec §3.7 §9.1 §9.3). network_role=standalone => the module derives project_id
# "csyn-ldg-validator-prod", stamps business_line=everforge + sensitive
# data-classification + deletion_policy=PREVENT, and creates the project + a
# dedicated workload SA. NO Shared-VPC attach: the validator runs on its OWN
# minimal VPC (network.tf), isolated from the testnet SVPC by design.
#
# The VM (Shielded n2d-highmem-8, non-confidential, reserved EIP, dUNL config) is
# booted by module "node" below. Its shape is surfaced as ledger-service inputs
# here so the project's contract (machine_type / disk_profile / budget) is fixed.
module "validator" {
  # CONSPLIT2: modules' one home is the sibling practice repo (csyn-consensus-infra);
  # this prod repo references them by pinned git tag. ledger-service transitively
  # git-sources modules/service-project from cloud-syndicate-platform@v0.1.0.
  source = "git::https://github.com/csyn-portfolio/csyn-consensus-infra.git//modules/ledger-service?ref=v0.2.0"

  tenant              = "ldg"
  env                 = "prod"
  role                = "validator"
  network_role        = "standalone"
  create_compute_sa   = true                                                                                # CS baseline #4 — dedicated workload SA, never the default
  data_classification = "sensitive"                                                                         # mainnet signing node (vs internal testnet)
  folder_id           = data.terraform_remote_state.org_foundation.outputs.folder_ledger_prod_validators_id # CONSVAL2 Path-B: move into ledger/prod/validators (in-place folder_id change, no-downtime; plan MUST show ~folder_id / 0 destroy)

  activate_apis = [
    "compute.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudkms.googleapis.com",
    "dns.googleapis.com", # restricted-VIP private zone (dns-restricted.tf)
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "iap.googleapis.com",              # IAP tunnel IAM (iam.tf validator_ops_ssh) reads/writes the tunnelinstance IAM policy — 403 "IAP API not used" at apply without it (CONSVAL1-A7)
    "artifactregistry.googleapis.com", # image pull from csyn-ldg-images (xrpld + sidecar)
  ]

  machine_type       = "n2d-highmem-8" # CONSVAL1 mainnet standard; non-confidential (us-south1 offers no Confidential VM, verified 2026-06-18)
  disk_profile       = "pd-ssd-150"    # CONSVAL1-A2: n2d CANNOT attach hyperdisk-balanced (API 400, verified 2026-06-18); pd-ssd is n2d-native + CMEK + IOPS scales with the vertical-resize lever. Metadata-only (not consumed in a resource).
  provisioning_model = "STANDARD"      # never Spot — dUNL clock continuity (spec §9.1)
  # n2d-highmem-8 + 150 GB pd-ssd ≈ $326/mo machine (1yr CUD) + ~$25/mo disk + variable P2P egress; 850 = steady-state x1.28 headroom for egress spikes (finops re-audit, 2026-08-08).
  monthly_budget_usd    = 850
  notification_channels = local.alert_channels # monitoring.tf — email (+ Slack once token supplied); budget alerts fan out through the same channels as node alerting
}

# API-propagation gate (cs-terraform-overlay rule #7). modules/service-project
# enables compute/dns/secretmanager/kms with no buffer; this root then calls those
# APIs (VPC, DNS zone, SM service identity, secret). For network_role=standalone
# the module's own time_sleep.svc_api is count=0, so this root carries the gate
# (mirrors host-dev/host.tf).
resource "time_sleep" "apis" {
  depends_on      = [module.validator]
  create_duration = "120s"
}

# ---------------------------------------------------------------------------
# Mainnet validator VM (CONSVAL1 — sprint Task 9)
# NON-confidential: us-south1 offers no Confidential VM (SEV-SNP or TDX), verified
# 2026-06-18, and no XRPL requirement mandates it. Dropping it removes ONLY in-use
# memory encryption + boot attestation; the rest of the tight posture is retained:
# Shielded VM (secure boot + vTPM + integrity monitoring), CMEK on both disks
# (sensitive data-classification; the data disk holds the boot-injected token),
# HSM-CMEK on the token secret, offline master key (revocable on-box token only),
# egress deny-floor, localhost-only admin RPC. n2d-highmem-8 (machine_type var —
# controlled vertical resize). STANDARD provisioning + on_host_maintenance=MIGRATE
# (survive host maintenance without a reboot->resync->missed-validations).
# ---------------------------------------------------------------------------

locals {
  validator_image = "us-south1-docker.pkg.dev/csyn-ldg-host-dev/csyn-ldg-images/rippled@${var.image_digest}"
  sidecar_image   = "us-south1-docker.pkg.dev/csyn-ldg-host-dev/csyn-ldg-images/xrpl-sidecar@${var.sidecar_image_digest}"
  validator_cfg   = templatefile("${path.module}/config/rippled.cfg.tftpl", {})
  validators      = file("${path.module}/config/validators.txt")
}

module "node" {
  # CONSPLIT2: pinned git tag from the sibling practice repo (one home). Self-contained.
  source = "git::https://github.com/csyn-portfolio/csyn-consensus-infra.git//modules/ledger-node?ref=v0.2.0"

  name       = "csyn-ldg-validator"
  project_id = module.validator.project_id
  zone       = "us-south1-a" # MUST match the Phase-0 vmExternalIpAccess self-link zone

  machine_type = var.machine_type
  node_size    = "huge" # module precondition: n2d-highmem-8 -> huge

  provisioning_model  = "STANDARD" # never Spot — dUNL clock continuity (spec §9.1)
  shielded            = true       # secure boot + vTPM + integrity monitoring
  on_host_maintenance = "MIGRATE"  # non-confidential -> live-migrate through host maintenance (no resync)

  boot_disk_size = 20
  data_disk_size = 150
  # pd-ssd, NOT hyperdisk-balanced: the n2d series cannot attach hyperdisk-balanced
  # (API 400 at create, verified 2026-06-18 us-south1-a — tofu plan does NOT catch
  # machine<->disk compatibility). At 8 vCPU the per-VM IOPS cap is the binding limit,
  # so hyperdisk/pd-extreme provisioned IOPS can't be consumed anyway; pd-ssd is the
  # cheapest n2d-native type that meets a validator's IOPS need, and its ceiling rises
  # with the machine_type vertical-resize lever (8->16->32) for free. (CONSVAL1-A2.)
  boot_disk_type = "pd-ssd"
  data_disk_type = "pd-ssd"
  # CMEK on both disks by CHOICE (sensitive data-classification; the data disk holds the
  # boot-injected [validator_token]) — no longer a confidential_vm precondition. pd-ssd
  # honors CMEK. Keys from bootstrap/kms (Pete-apply Task 1: HSM keyring + disk key +
  # compute-agent bind).
  boot_disk_kms_key = data.terraform_remote_state.kms.outputs.ledger_validator_disk_key_hsm
  data_disk_kms_key = data.terraform_remote_state.kms.outputs.ledger_validator_disk_key_hsm

  subnetwork            = google_compute_subnetwork.validator.id # csyn-ldg-validator-us-south1, 10.60.0.0/28
  network_ip            = "10.60.0.4"                            # static host in /28
  internal_ingress_cidr = "10.60.0.0/28"
  external_ip           = google_compute_address.validator_p2p.address
  service_account_email = module.validator.workload_sa

  image_ref         = local.validator_image
  rippled_cfg       = local.validator_cfg
  validators_txt    = local.validators
  token_secret_name = google_secret_manager_secret.validator_token.secret_id

  sidecar_image_ref       = local.sidecar_image
  sidecar_metric_location = "us-south1"

  # Telemetry-first observability (CONSVAL1 Task 12): ship the xrpld container's
  # stdout/stderr to Cloud Logging. Validator-only — the workload SA already holds
  # logging.logWriter (iam.tf, applied with the validator), so gcplogs won't
  # fail-closed; takes effect on the next instance reset (every-boot recreate).
  enable_gcplogs = true

  depends_on = [google_compute_address.validator_p2p, time_sleep.apis]
}
