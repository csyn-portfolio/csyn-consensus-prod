# gcplogs hard-fails `docker run` without this (readiness #6/#14). Granted in this
# PRIOR apply (not the VM apply) so the binding is propagated before the VM boots.
resource "google_project_iam_member" "validator_log_writer" {
  project = module.validator.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${module.validator.workload_sa}"
}

# The on-VM monitoring sidecar (ledger-node module) writes custom metrics as the
# VM workload SA over the restricted VIP. metricWriter covers timeSeries.create
# for custom metrics. Granted in this PRIOR apply so it propagates before the VM
# reset that starts the sidecar container.
resource "google_project_iam_member" "validator_metric_writer" {
  project = module.validator.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${module.validator.workload_sa}"
}

# Cross-project image pull (CONSVAL1-A5): the validator runs the dev-vetted rippled
# image from host-dev's AR repo (validator.tf image_ref =
# us-south1-docker.pkg.dev/csyn-ldg-host-dev/csyn-ldg-images/...). A cross-project
# pull needs the workload SA granted reader on that repo — the in-project dev nodes
# never needed it, but the standalone validator project does (mirrors
# svc-rippled-dev/main.tf image_pull). Coords hardcoded to match the image_ref
# constant; the validator deliberately does NOT wire host-dev's remote state
# (standalone by design). Applied before the VM reset, so the grant propagates
# ahead of the boot docker pull.
resource "google_artifact_registry_repository_iam_member" "image_pull" {
  project    = "csyn-ldg-host-dev"
  location   = "us-south1"
  repository = "csyn-ldg-images"
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${module.validator.workload_sa}"
}

# IAP-SSH operator access for Task-10 verification (CONSVAL1) — isolated and
# INSTANCE-scoped (not project-wide). Bound to a dedicated Workspace group, NOT a
# direct user (H7 + M12(b) identity-hygiene convention, AC-6(5)): membership rotates
# in admin.google.com, never via a TF apply. The group is scoped to the mainnet
# SIGNING node alone — lower-sensitivity dev/clio/flare nodes get their own group.
# PREREQUISITE: csyn-ledger-validator-ops@cloudsyn.net must be created in the Workspace
# Admin Console (Security group; owner + member pete@) BEFORE apply — you cannot bind a
# group that does not exist (mirrors the H7 group-first sequence).
# Two instance-scoped grants:
#   1. iap.tunnelResourceAccessor — broker the IAP TCP tunnel to :22 (paired with the
#      iap_ssh_in firewall allow).
#   2. compute.osLogin — POSIX login via OS Login, ENFORCED org-wide
#      (compute.requireOsLogin, verified effective 2026-06-18). Non-sudo is sufficient
#      to curl the localhost:5005 admin RPC; a future broader-priv group would take
#      roles/compute.osAdminLogin if container/host ops need root.
# ledger-apply holds roles/owner on this project, so CI can set instance IAM. Metadata-
# key SSH is deliberately NOT used — OS Login enforcement supersedes it.
locals {
  validator_ops_group = "group:csyn-ledger-validator-ops@cloudsyn.net"
}

# New-API propagation gate (cs-terraform-overlay rule #7; CONSVAL1-A7). iap.googleapis.com
# is freshly enabled in validator.tf activate_apis. The existing time_sleep.apis does NOT
# re-trigger on a re-apply where the instance already exists, so without this the IAP IAM
# write below races API propagation and 403s ("IAP API ... used ... recently, wait a few
# minutes"). Gate ONLY the tunnel IAM (osLogin uses compute.googleapis.com, long-enabled).
resource "time_sleep" "iap_api" {
  depends_on      = [module.validator]
  create_duration = "120s"
}

resource "google_iap_tunnel_instance_iam_member" "validator_ops_ssh" {
  project  = module.validator.project_id
  zone     = module.node.zone
  instance = module.node.instance_name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = local.validator_ops_group

  depends_on = [time_sleep.iap_api]
}

resource "google_compute_instance_iam_member" "validator_ops_oslogin" {
  project       = module.validator.project_id
  zone          = module.node.zone
  instance_name = module.node.instance_name
  role          = "roles/compute.osLogin"
  member        = local.validator_ops_group
}
