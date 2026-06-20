# poller.tf — agreement / missed-validations poller (spec 2026-06-19).
# A Cloud Run JOB fired every 10 min by Cloud Scheduler reads our validator's
# rolling-1h agreement from the PUBLIC validations.xrpl.org and writes it as a
# custom metric. Public-API-only: no VPC, no admin RPC. Folds into this root.

locals {
  poller_image = "us-south1-docker.pkg.dev/csyn-ldg-host-dev/csyn-ldg-images/xrpl-poller@${var.poller_image_digest}"
}

# --- Identity: two least-privilege SAs ---------------------------------------
resource "google_service_account" "poller_runtime" {
  project      = module.validator.project_id
  account_id   = "xrpl-poll-runtime"
  display_name = "xrpl agreement poller — runtime (metric writer)"
}

resource "google_service_account" "poller_scheduler" {
  project      = module.validator.project_id
  account_id   = "xrpl-poll-scheduler"
  display_name = "xrpl agreement poller — scheduler invoker"
}

resource "google_project_iam_member" "poller_metric_writer" {
  project = module.validator.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.poller_runtime.email}"
}

# --- Cross-project image pull (firehose image_pull_run_agent pattern) ---------
# Cloud Run pulls via the project SERVICE AGENT, not the runtime SA.
#
# Materialize the Cloud Run serverless-robot agent FIRST (google-beta, mirrors
# secret-cmek.tf's secretmanager identity). Enabling run.googleapis.com does NOT
# create the agent eagerly — it's lazy-created on the first Cloud Run resource.
# But the poller job is count-gated out until the image digest is pinned, so the
# staged Apply #1 has NO Cloud Run resource to trigger it; granting AR-reader to
# the not-yet-existent agent 400s ("service account ... does not exist"). firehose
# never hit this because its worker-pool resource creates in the same apply.
# generateServiceIdentity (this resource) creates the agent deterministically and
# yields its email — no hand-built string, no project-number copy.
resource "google_project_service_identity" "run_agent" {
  provider   = google-beta
  project    = module.validator.project_id
  service    = "run.googleapis.com"
  depends_on = [time_sleep.apis]
}

resource "google_artifact_registry_repository_iam_member" "poller_image_pull_run_agent" {
  project    = "csyn-ldg-host-dev"
  location   = "us-south1"
  repository = "csyn-ldg-images"
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_project_service_identity.run_agent.email}"
}

# Cross-project AR IAM is eventually consistent — gate the job behind propagation
# (no networkUser/networkViewer here: poller has NO Direct-VPC egress).
resource "time_sleep" "wait_poller_run_agent_iam" {
  depends_on      = [google_artifact_registry_repository_iam_member.poller_image_pull_run_agent]
  create_duration = "120s"
}

# --- Custom metric descriptors (explicit, not auto-created) -------------------
resource "google_monitoring_metric_descriptor" "agreement_1h" {
  project      = module.validator.project_id
  type         = "custom.googleapis.com/xrpl/validator/agreement_1h"
  metric_kind  = "GAUGE"
  value_type   = "DOUBLE"
  unit         = "1"
  display_name = "XRPL validator 1h agreement ratio"
  description  = "Rolling 1h agreement from validations.xrpl.org, keyed by our published validation key."
}

resource "google_monitoring_metric_descriptor" "poller_heartbeat" {
  project      = module.validator.project_id
  type         = "custom.googleapis.com/xrpl/validator/poller_heartbeat"
  metric_kind  = "GAUGE"
  value_type   = "DOUBLE"
  unit         = "1"
  display_name = "XRPL agreement poller heartbeat"
  description  = "Written 1.0 on every successful poll cycle; absence => poller down."
}

# --- Cloud Run JOB (staged create, like firehose) ----------------------------
resource "google_cloud_run_v2_job" "poller" {
  count    = var.poller_image_digest == "" ? 0 : 1
  project  = module.validator.project_id
  name     = "xrpl-validations-poll"
  location = "us-south1"

  template {
    template {
      timeout         = "60s"
      max_retries     = 0
      service_account = google_service_account.poller_runtime.email
      containers {
        image = local.poller_image
        resources {
          limits = {
            cpu    = "1" # Cloud Run JOB hard floor (no fractional CPU)
            memory = "512Mi"
          }
        }
        env {
          name  = "VALIDATOR_PUBKEY"
          value = var.validator_pubkey
        }
        env {
          name  = "GCP_PROJECT"
          value = module.validator.project_id
        }
        env {
          name  = "METRIC_LOCATION"
          value = "us-south1"
        }
      }
      # NO vpc_access => public internet egress (intended).
    }
  }
  depends_on = [time_sleep.wait_poller_run_agent_iam]
}

# --- Cloud Scheduler -> Run Admin API (oauth_token, zero ingress) -------------
resource "google_cloud_run_v2_job_iam_member" "scheduler_invoke" {
  count    = var.poller_image_digest == "" ? 0 : 1
  project  = google_cloud_run_v2_job.poller[0].project
  location = google_cloud_run_v2_job.poller[0].location
  name     = google_cloud_run_v2_job.poller[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.poller_scheduler.email}"
}

resource "google_cloud_scheduler_job" "poller" {
  count     = var.poller_image_digest == "" ? 0 : 1
  project   = module.validator.project_id
  name      = "xrpl-validations-poll"
  region    = "us-south1"
  schedule  = "*/10 * * * *"
  time_zone = "Etc/UTC"

  retry_config {
    retry_count = 0 # a missed run is covered by the next fire (gap is itself a signal)
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${module.validator.project_id}/locations/us-south1/jobs/${google_cloud_run_v2_job.poller[0].name}:run"
    oauth_token {
      service_account_email = google_service_account.poller_scheduler.email # oauth (Google API), NOT oidc
    }
  }
}
