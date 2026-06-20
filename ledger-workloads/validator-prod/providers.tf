terraform {
  required_version = ">= 1.9.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    # google-beta carries google_project_service_identity (secret-cmek.tf) — the
    # deterministic way to materialize the Secret Manager service agent before
    # binding it to the CMEK key.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
    # time_sleep gates API-enable propagation before the consuming resources
    # (compute/dns/secretmanager) — cs-terraform-overlay rule #7.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

# billing_project = csyn-platform: quota attributed centrally; the impersonated
# ledger-apply SA holds serviceUsageConsumer on csyn-platform (Task 0.2).
provider "google" {
  region                = "us-south1"
  billing_project       = "csyn-platform"
  user_project_override = true
}

provider "google-beta" {
  region                = "us-south1"
  billing_project       = "csyn-platform"
  user_project_override = true
}
