# public-status-publisher.tf — Cloud Run Job + 5m Cloud Scheduler that publishes
# tools/publish_public_status.py → gs://csyn-www-validator1-toml/{status,history}.json
#
# Reads sidecar gauges in this project (Monitoring) + data.xrpl.org agreement
# (public HTTPS). Writes public status objects to the www trust-card bucket
# (cross-project objectAdmin). Scheduler lives in us-central1 (Scheduler not in
# us-south1 — same pattern as power-scheduler / retired poller).
#
# Gated on var.public_status_image_digest (empty = no job/cron; CI plan green).
#
# PRIMARY publisher today: GHA .github/workflows/publish-validator1-status.yml
# (*/5 on main). Do NOT set public_status_image_digest while that workflow is
# enabled — two writers race on history.json (I2). Cutover: disable GHA, pin digest, apply.
#
# SAs v1-public-status / v1-public-status-inv already exist (bootstrap). Use data
# sources so apply does not 409 alreadyExists (C2 gate finding).

locals {
  pub_status_image = (
    var.public_status_image_digest != ""
    ? "us-south1-docker.pkg.dev/csyn-ldg-host-dev/csyn-ldg-images/validator1-status-publisher@${var.public_status_image_digest}"
    : ""
  )
  pub_status_on = var.public_status_image_digest != ""
}

data "google_service_account" "public_status_publisher" {
  account_id = "v1-public-status"
  project    = module.validator.project_id
}

data "google_service_account" "public_status_invoker" {
  account_id = "v1-public-status-inv"
  project    = module.validator.project_id
}

resource "google_project_iam_member" "public_status_monitoring_viewer" {
  project = module.validator.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${data.google_service_account.public_status_publisher.email}"
}

# The publisher's write access to gs://csyn-www-validator1-toml is NOT declared here.
# That bucket belongs to cloud-syndicate-platform (shared/www/validator1.tf creates it,
# in project csyn-www-prod), and IAM on a resource belongs with the resource.
#
# This root did declare it, and could not apply it — this repo's apply SA cannot read,
# let alone write, that bucket's IAM policy across the project boundary, so the 403 took
# down the entire root's apply rather than just this one binding:
#   OBSERVED: apply run 31444004150 -> "Error 403: ledger-apply@csyn-platform
#     .iam.gserviceaccount.com does not have storage.buckets.getIamPolicy access to
#     ... csyn-www-validator1-toml"; the other six resources in that plan had already
#     applied successfully @ 2026-08-10
#
# One home: cloud-syndicate-platform shared/www/validator1.tf,
# google_storage_bucket_iam_member.validator1_public_status_publisher. If the publisher
# ever loses write access, that is the file to look in — not this one.
#
# Open follow-up carried over from the removed resource: objectAdmin is broader than
# needed. A custom role scoped to status.json and history.json would be tighter, and it
# would now be authored in the owning repo.

# --- Cloud Run service agent → AR pull (csyn-ldg-images) ----------------------
resource "google_project_service_identity" "run_agent_public_status" {
  count      = local.pub_status_on ? 1 : 0
  provider   = google-beta
  project    = module.validator.project_id
  service    = "run.googleapis.com"
  depends_on = [time_sleep.apis]
}

resource "google_artifact_registry_repository_iam_member" "public_status_image_pull" {
  count      = local.pub_status_on ? 1 : 0
  project    = "csyn-ldg-host-dev"
  location   = "us-south1"
  repository = "csyn-ldg-images"
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_project_service_identity.run_agent_public_status[0].email}"
}

resource "time_sleep" "wait_public_status_ar" {
  count           = local.pub_status_on ? 1 : 0
  depends_on      = [google_artifact_registry_repository_iam_member.public_status_image_pull]
  create_duration = "60s"
}

# --- Cloud Run Job ------------------------------------------------------------
resource "google_cloud_run_v2_job" "public_status" {
  count    = local.pub_status_on ? 1 : 0
  project  = module.validator.project_id
  name     = "validator1-public-status"
  location = "us-south1"

  template {
    template {
      timeout         = "120s"
      max_retries     = 1
      service_account = data.google_service_account.public_status_publisher.email
      containers {
        image = local.pub_status_image
        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
        env {
          name  = "GOOGLE_CLOUD_PROJECT"
          value = module.validator.project_id
        }
      }
    }
  }

  depends_on = [time_sleep.wait_public_status_ar]
}

resource "google_cloud_run_v2_job_iam_member" "public_status_invoker" {
  count    = local.pub_status_on ? 1 : 0
  project  = google_cloud_run_v2_job.public_status[0].project
  location = google_cloud_run_v2_job.public_status[0].location
  name     = google_cloud_run_v2_job.public_status[0].name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.public_status_invoker.email}"
}

# Scheduler not available in us-south1 → us-central1, Admin API global.
resource "google_cloud_scheduler_job" "public_status_5m" {
  count       = local.pub_status_on ? 1 : 0
  project     = module.validator.project_id
  region      = "us-central1"
  name        = "validator1-public-status-5m"
  schedule    = "*/5 * * * *"
  time_zone   = "UTC"
  description = "Publish validator1 status.json + history.json every 5 minutes"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${module.validator.project_id}/locations/us-south1/jobs/${google_cloud_run_v2_job.public_status[0].name}:run"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode("{}")
    oauth_token {
      service_account_email = data.google_service_account.public_status_invoker.email
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.public_status_invoker]
}
