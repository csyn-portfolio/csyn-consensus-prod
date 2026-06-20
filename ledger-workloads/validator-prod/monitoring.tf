# monitoring.tf — first observability/alerting config for the standalone mainnet
# validator (CONSVAL1 Task 12, observability second half). FIRST-OF-KIND alerting in
# this repo; designed via a gcp-arch-expert:observability-sre consult (2026-06-19) with
# the load-bearing GCP behaviors verified:
#   - Log-based COUNTER metrics emit DATA GAPS (not zeros) when nothing matches, so
#     "node down" uses condition_absent on a log-presence metric. A threshold "< 1"
#     would never fire — there is no zero datapoint to compare against during silence.
#   - condition_matched_log REQUIRES alert_strategy.notification_rate_limit (API rejects without).
#   - email notification channels are usable on apply — no verification click.
# monitoring.googleapis.com is already enabled (validator.tf activate_apis); the logs
# already flow (gcplogs), so log-based metrics derived from them add NO new ingestion (free).
#
# Pass 1 ships down + secret-fail + stuck. DEFERRED to a separate root (documented in
# docs/dev-to-prod-readiness.md): the low-agreement / missed-validations + precise
# server_state=proposing poller — those live on xrpscan/validations.xrpl.org, NOT native
# Cloud Monitoring metrics (Cloud Scheduler -> Cloud Function -> custom metric).

locals {
  validator_gcplogs = "projects/${module.validator.project_id}/logs/gcplogs-docker-driver"
  # The boot secret-fetch + fail-closed `exit 1` runs in the HOST startup-script (before
  # `docker run`), so its output lands in google_metadata_script_runner — NOT the container
  # gcplogs stream. (Verified 2026-06-19: serial-port logging off; script-runner logs present
  # with jsonPayload.message.) Re-targeted from the consult's gcplogs filter, which would
  # never have matched the host-side line.
  validator_startup_log = "projects/${module.validator.project_id}/logs/google_metadata_script_runner"
}

# --- Notification channel (prerequisite for all policies) ---------------------
# email channel is live on apply (no verification flow, unlike sms/webhook).
# pete@cloudsyn.net is also the inherited essential contact (SECURITY/TECHNICAL).
resource "google_monitoring_notification_channel" "pete_email" {
  project      = module.validator.project_id
  display_name = "Pete (cloudsyn.net) — validator-prod"
  type         = "email"
  labels = {
    email_address = "pete@cloudsyn.net"
  }
}

# --- Heartbeat metrics (zero labels — cardinality guard; pure heartbeats) ------
# Counts EVERY xrpld container line. At log_level=info a healthy node emits many
# lines/sec, so the series is continuous; container exit / VM death / gcplogs failure
# -> the series GAPS -> validator_down fires.
resource "google_logging_metric" "validator_log_presence" {
  project = module.validator.project_id
  name    = "validator/log_presence"
  filter  = "logName=\"${local.validator_gcplogs}\" AND resource.type=\"gce_instance\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Consensus-activity heartbeat: LedgerConsensus lines flow continuously while proposing.
# A multi-minute gap = wedged (a ~2min reboot resync still emits consensus lines).
resource "google_logging_metric" "validator_consensus_activity" {
  project = module.validator.project_id
  name    = "validator/consensus_activity"
  filter  = "logName=\"${local.validator_gcplogs}\" AND jsonPayload.message=~\"LedgerConsensus:(NFO|WRN)\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Log-based metric descriptors take a few minutes to become QUERYABLE after creation
# ("up to 10 minutes" per the Monitoring API). The condition_absent policies below
# reference these metric types, so creating them in the SAME apply 404s ("Cannot find
# metric(s) that match type ..."). Gate the metric-referencing policies behind this
# propagation wait (cs-terraform-overlay rule #7; empirically hit 2026-06-19 — the first
# apply created the channel + both metrics but failed validator_down + validator_stuck).
resource "time_sleep" "metrics_ready" {
  depends_on      = [google_logging_metric.validator_log_presence, google_logging_metric.validator_consensus_activity]
  create_duration = "300s"
}

# --- Alert policies -----------------------------------------------------------
# HIGH — validator DOWN: no container logs for 5m. Covers VM-down, container exit
# (incl. a fail-closed boot that never reaches `docker run`), and gcplogs death.
# 5m of TOTAL silence is unambiguous (ledger closes every ~3-4s; a resync still logs).
resource "google_monitoring_alert_policy" "validator_down" {
  project      = module.validator.project_id
  display_name = "Validator DOWN — no xrpld logs (5m)"
  combiner     = "OR"
  depends_on   = [time_sleep.metrics_ready] # metric descriptor must be queryable first
  conditions {
    display_name = "No xrpld log lines for 5m"
    condition_absent {
      filter   = "resource.type=\"gce_instance\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.validator_log_presence.name}\""
      duration = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_COUNT"
      }
      trigger { count = 1 }
    }
  }
  notification_channels = [google_monitoring_notification_channel.pete_email.id]
  alert_strategy { auto_close = "1800s" }
  documentation {
    content   = "No xrpld log lines reached Cloud Logging for 5 minutes — the validator container or COS VM is down (or gcplogs stopped). A down validator misses validations (UNL curators score this). Check `gcloud compute instances describe csyn-ldg-validator --zone us-south1-a`, then IAP-SSH + `docker ps`. Runbook: docs/runbooks/validator-buildout-and-domain-verification.md."
    mime_type = "text/markdown"
  }
}

# HIGH — secret-load fail-closed at boot. Host startup-script logs this to
# google_metadata_script_runner (runs before `docker run`, so NOT in gcplogs).
resource "google_monitoring_alert_policy" "validator_secret_fail" {
  project      = module.validator.project_id
  display_name = "Validator secret-load FAILED at boot"
  combiner     = "OR"
  conditions {
    display_name = "FAILED to load token from Secret Manager"
    condition_matched_log {
      filter = "logName=\"${local.validator_startup_log}\" AND jsonPayload.message=~\"validator: FAILED to load token from Secret Manager\""
    }
  }
  notification_channels = [google_monitoring_notification_channel.pete_email.id]
  # REQUIRED for condition_matched_log — the API rejects the policy without it.
  alert_strategy {
    notification_rate_limit { period = "300s" }
  }
  documentation {
    content   = "The validator failed to fetch its [validator_token] from Secret Manager at boot and fail-closed (exit 1; the container never started). The node is NOT validating. Check Secret Manager access + that the FULL [validator_token] stanza (header included) is stored. See feedback-validator-token-secret-stanza + the runbook."
    mime_type = "text/markdown"
  }
}

# MEDIUM (lenient) — possibly STUCK: no LedgerConsensus activity for 15m. A normal
# post-reboot resync (~2min connected/wrongLedger) still emits consensus lines, so 15m
# of NONE = genuinely wedged. Does NOT catch "logs flow but server_state stays connected"
# — that precise check belongs to the deferred poller.
resource "google_monitoring_alert_policy" "validator_stuck" {
  project      = module.validator.project_id
  display_name = "Validator possibly STUCK — no consensus activity (15m)"
  combiner     = "OR"
  depends_on   = [time_sleep.metrics_ready] # metric descriptor must be queryable first
  conditions {
    display_name = "No LedgerConsensus lines for 15m"
    condition_absent {
      filter   = "resource.type=\"gce_instance\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.validator_consensus_activity.name}\""
      duration = "900s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_COUNT"
      }
      trigger { count = 1 }
    }
  }
  notification_channels = [google_monitoring_notification_channel.pete_email.id]
  alert_strategy { auto_close = "1800s" }
  documentation {
    content   = "No LedgerConsensus activity for 15m — the node may be wedged (stuck connected/wrongLedger, not proposing). A short post-reboot resync (~2min) will NOT trigger this. Check `server_info` mode via the localhost admin RPC (expect `proposing`). Runbook: docs/runbooks/validator-buildout-and-domain-verification.md."
    mime_type = "text/markdown"
  }
}

# --- Agreement-low: validator missing/disagreeing on validations ---------------
# 0.99 is a STARTING floor — tune to the observed baseline after a few days
# (spec §7). 30-min duration absorbs the benign ~2-min post-reset resync.
resource "google_monitoring_alert_policy" "agreement_low" {
  project      = module.validator.project_id
  display_name = "XRPL validator agreement DEGRADED (<0.99 for 30m)"
  combiner     = "OR"

  conditions {
    display_name = "agreement_1h < 0.99 sustained"
    condition_threshold {
      filter          = "metric.type=\"custom.googleapis.com/xrpl/validator/agreement_1h\" AND resource.type=\"generic_task\""
      comparison      = "COMPARISON_LT"
      threshold_value = 0.99
      duration        = "1800s"
      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_MEAN"
      }
      trigger { count = 1 }
    }
  }

  notification_channels = [google_monitoring_notification_channel.pete_email.id]
  alert_strategy { auto_close = "1800s" }
  depends_on = [google_monitoring_metric_descriptor.agreement_1h]
}

# --- Poller-down: heartbeat absent (mirror of the log-metric gap lesson) -------
resource "google_monitoring_alert_policy" "poller_down" {
  project      = module.validator.project_id
  display_name = "XRPL agreement poller — DOWN (no heartbeat)"
  combiner     = "OR"

  conditions {
    display_name = "poller_heartbeat absent > 35m"
    condition_absent {
      filter   = "metric.type=\"custom.googleapis.com/xrpl/validator/poller_heartbeat\" AND resource.type=\"generic_task\""
      duration = "2100s" # survives 1 missed run @10m, fires on ~3 consecutive
      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_COUNT"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.pete_email.id]
  alert_strategy { auto_close = "1800s" } # condition_absent needs NO notification_rate_limit
  depends_on = [google_monitoring_metric_descriptor.poller_heartbeat]
}
