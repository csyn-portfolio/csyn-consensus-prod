# TEMPORARY — poller teardown recovery (2026-06-20). DELETE in the follow-up PR.
#
# The poller cutover (PR #4) removed the Cloud Run job, but google_cloud_run_v2_job
# defaults deletion_protection=true (a PROVIDER-side guard; the API field is unset),
# so the destroy aborted: "cannot destroy job without setting deletion_protection=
# false and running apply". This file restores the still-in-state job (+ its runtime
# SA) with deletion_protection=false so this apply unprotects it IN-PLACE. The
# follow-up PR deletes this file → the now-unprotected job destroys cleanly.
# This is the two-step deletion_protection dance; nothing here is permanent.

variable "poller_image_digest" {
  description = "Pinned digest of the (being-retired) xrpl-poller image. Restored only to satisfy the lingering job during teardown; removed with this file."
  type        = string
  default     = "sha256:b95d9a26b2d9f5e902a8b523b01dec8d8955fe43f17613954956ea2dc45b9c69"
}

locals {
  poller_image = "us-south1-docker.pkg.dev/csyn-ldg-host-dev/csyn-ldg-images/xrpl-poller@${var.poller_image_digest}"
}

resource "google_service_account" "poller_runtime" {
  project      = module.validator.project_id
  account_id   = "xrpl-poll-runtime"
  display_name = "xrpl agreement poller — runtime (metric writer)"
}

resource "google_cloud_run_v2_job" "poller" {
  count               = var.poller_image_digest == "" ? 0 : 1
  project             = module.validator.project_id
  name                = "xrpl-validations-poll"
  location            = "us-south1"
  deletion_protection = false

  template {
    template {
      timeout         = "60s"
      max_retries     = 0
      service_account = google_service_account.poller_runtime.email
      containers {
        image = local.poller_image
        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
        env {
          name  = "VALIDATOR_PUBKEY"
          value = "nHUQEd51hNxF3vdVHJKewxZUzXqiP78agDL2bVSiA7Ja4dRFZUGq"
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
    }
  }
}
