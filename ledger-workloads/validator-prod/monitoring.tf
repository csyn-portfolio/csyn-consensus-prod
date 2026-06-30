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

# Slack channel — a redundant alert path of a DIFFERENT type than email
# (observability-sre consult 2026-06-21: best-effort email alone is inadequate
# for a regulated prod validator). GATED on the token: empty var.slack_auth_token
# => count 0 => not created, CI plan stays green. The token requires authorizing
# the "Google Cloud Monitoring" Slack app in the workspace (interactive, Pete-only;
# Monitoring > Alerting > Notification channels > Slack), then supply via -var or
# a GH secret at apply — never commit it.
resource "google_monitoring_notification_channel" "slack" {
  count        = var.slack_auth_token != "" ? 1 : 0
  project      = module.validator.project_id
  display_name = "Slack ${var.slack_channel_name} — validator-prod"
  type         = "slack"
  labels = {
    channel_name = var.slack_channel_name
  }
  sensitive_labels {
    auth_token = var.slack_auth_token
  }
}

locals {
  # Every alert policy fans out to email + (once configured) Slack. Both channels
  # receive all policies; narrow Slack to CRITICAL-only later if it gets noisy.
  alert_channels = concat(
    [google_monitoring_notification_channel.pete_email.id],
    google_monitoring_notification_channel.slack[*].id,
  )
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
  notification_channels = local.alert_channels
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
  notification_channels = local.alert_channels
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
  notification_channels = local.alert_channels
  alert_strategy { auto_close = "1800s" }
  documentation {
    content   = "No LedgerConsensus activity for 15m — the node may be wedged (stuck connected/wrongLedger, not proposing). A short post-reboot resync (~2min) will NOT trigger this. Check `server_info` mode via the localhost admin RPC (expect `proposing`). Runbook: docs/runbooks/validator-buildout-and-domain-verification.md."
    mime_type = "text/markdown"
  }
}

# --- Sidecar-down: heartbeat absent (mirror of the log-metric gap lesson) ------
# poller_heartbeat is now emitted by the on-VM sidecar (resource label kept to
# preserve metric/alert continuity through the poller→sidecar cutover).
resource "google_monitoring_alert_policy" "poller_down" {
  project      = module.validator.project_id
  display_name = "XRPL sidecar — DOWN (no heartbeat)"
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

  notification_channels = local.alert_channels
  alert_strategy { auto_close = "1800s" } # condition_absent needs NO notification_rate_limit
  depends_on = [google_monitoring_metric_descriptor.poller_heartbeat]
}

# --- Amendment in majority window: the ~14-day upgrade deadline ----------------
# Proactive amendment-blocked defense (poller >= 0.2.0). When >=1 amendment is
# enabled=false with majority set, the ~2-week activation clock is running: a
# validator NOT on a supporting xrpld binary becomes amendment-blocked and stops
# validating at activation (rollback impossible). This is the lead-time alert —
# act before activation. Threshold-on-custom-metric (amendments_in_majority_window GAUGE).
resource "google_monitoring_alert_policy" "amendment_in_majority" {
  project      = module.validator.project_id
  display_name = "XRPL amendment in majority window — confirm validator on a supporting binary"
  combiner     = "OR"

  conditions {
    display_name = "amendments_in_majority_window >= 1 (≈2-week activation clock)"
    condition_threshold {
      filter          = "metric.type=\"custom.googleapis.com/xrpl/validator/amendments_in_majority_window\" AND resource.type=\"generic_task\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.5 # GAUGE count; >0.5 means >=1
      duration        = "0s"
      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_MAX"
      }
      trigger { count = 1 }
    }
  }

  notification_channels = local.alert_channels
  # Amendment windows last ~2 weeks; keep the incident open a day so it re-surfaces
  # rather than flapping closed between 10-min polls.
  alert_strategy { auto_close = "86400s" }
  documentation {
    content   = "One or more XRPL amendments are in the majority activation window (≈2 weeks to activation). Confirm our validator's xrpld binary supports them (https://xrpl.org/resources/known-amendments + xrpscan amendments) — if not, schedule the rolling upgrade BEFORE activation or the node becomes amendment-blocked and stops validating. The radar email + GitHub release watch carry the upstream detail. Runbook: docs/runbooks/validator-buildout-and-domain-verification.md."
    mime_type = "text/markdown"
  }
  depends_on = [google_monitoring_metric_descriptor.amendments_in_majority_window]
}

# --- Amendment-blocked: the validator has STOPPED validating ------------------
# server_info.amendment_blocked == true means the node is on a binary that does
# not support an activated amendment; it stops validating and cannot roll back.
# Page immediately. The amendment_in_majority alert above is the lead-time warning;
# this is the failsafe if that window was missed.
resource "google_monitoring_alert_policy" "amendment_blocked" {
  project      = module.validator.project_id
  display_name = "XRPL validator AMENDMENT-BLOCKED — node stopped validating"
  combiner     = "OR"

  conditions {
    display_name = "amendment_blocked == 1"
    condition_threshold {
      filter          = "metric.type=\"custom.googleapis.com/xrpl/validator/amendment_blocked\" AND resource.type=\"generic_task\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.5
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MAX"
      }
      trigger { count = 1 }
    }
  }

  notification_channels = local.alert_channels
  alert_strategy { auto_close = "86400s" }
  documentation {
    content   = "The validator is AMENDMENT-BLOCKED: it is on a binary that does not support an amendment the network has activated, so it has stopped validating and CANNOT roll back. Upgrade the xrpld binary to a supporting release immediately. Runbook: docs/runbooks/validator-buildout-and-domain-verification.md."
    mime_type = "text/markdown"
  }
  depends_on = [google_monitoring_metric_descriptor.amendment_blocked]
}

# --- UNL freshness: a publisher list is going stale (leading indicator) --------
# The node refreshes its UNL over the peer protocol (no HTTP egress). When the
# EARLIEST publisher list is within 14 days of expiry, that publisher's P2P refresh
# may have stalled. This is a WARNING, not urgent: the node stays trusted as long as
# unl_max_days_to_expiry is high (the other publisher's list still covers it). It is
# the signal to investigate / consider the manual break-glass (WS2-D runbook).
resource "google_monitoring_alert_policy" "unl_min_expiry" {
  project      = module.validator.project_id
  display_name = "XRPL UNL — earliest publisher list within 14d of expiry (refresh may have stalled)"
  combiner     = "OR"

  conditions {
    display_name = "unl_min_days_to_expiry < 14"
    condition_threshold {
      filter          = "metric.type=\"custom.googleapis.com/xrpl/validator/unl_min_days_to_expiry\" AND resource.type=\"generic_task\""
      comparison      = "COMPARISON_LT"
      threshold_value = 14
      duration        = "600s" # slow-moving (≈1/day); 10m avoids a transient parse blip
      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_MIN"
      }
      trigger { count = 1 }
    }
  }

  notification_channels = local.alert_channels
  severity              = "WARNING"
  alert_strategy { auto_close = "86400s" }
  documentation {
    content   = "The earliest-expiring XRPL publisher list (Ripple or XRPLF) is within 14 days of expiry. The validator refreshes its UNL peer-to-peer (no HTTP egress); a stalling earliest list suggests that publisher's P2P refresh has lagged. NOT urgent if `unl_max_days_to_expiry` is still high — the other publisher's list keeps the node trusted (validator_list_threshold=1). In healthy operation the publisher reissues a later-dated list before this 14d window, so a sustained firing means refresh genuinely stalled. Action: check `validators` admin RPC publisher_lists[] expirations + that vetted hubs are peered; if neither list is refreshing, execute the manual UNL break-glass runbook (docs/runbooks/unl-break-glass.md). The CRITICAL counterpart is `unl_max_expiry`."
    mime_type = "text/markdown"
  }
  depends_on = [google_monitoring_metric_descriptor.unl_min_days_to_expiry]
}

# --- UNL freshness: node-stop horizon (CRITICAL failsafe) ---------------------
# unl_max_days_to_expiry is the latest available publisher list — the true point at
# which the node loses its trusted set entirely (no list left to satisfy the
# threshold). < 7 days means BOTH publishers have stopped refreshing and expiry is
# imminent: execute the break-glass before the node stops tracking consensus.
resource "google_monitoring_alert_policy" "unl_max_expiry" {
  project      = module.validator.project_id
  display_name = "XRPL UNL — node within 7d of losing its trusted validator list (break-glass)"
  combiner     = "OR"

  conditions {
    display_name = "unl_max_days_to_expiry < 7"
    condition_threshold {
      filter          = "metric.type=\"custom.googleapis.com/xrpl/validator/unl_max_days_to_expiry\" AND resource.type=\"generic_task\""
      comparison      = "COMPARISON_LT"
      threshold_value = 7
      duration        = "600s"
      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_MIN"
      }
      trigger { count = 1 }
    }
  }

  notification_channels = local.alert_channels
  severity              = "CRITICAL"
  alert_strategy { auto_close = "86400s" }
  documentation {
    content   = "CRITICAL: the LATEST-expiring XRPL publisher list is within 7 days of expiry — every cached publisher list is about to expire and P2P refresh has not delivered a newer one. When the last list expires the node loses its trusted validator set and stops tracking consensus. Execute the manual UNL break-glass NOW: fetch the current publisher-signed list in an egress-capable environment, deliver it via the restricted-VIP/GCS path, point `[validator_list_sites]` at the local `file:///` or `http://127.0.0.1` copy (the node verifies the publisher signature itself), then clock-safe recreate. Runbook: docs/runbooks/unl-break-glass.md."
    mime_type = "text/markdown"
  }
  depends_on = [google_monitoring_metric_descriptor.unl_max_days_to_expiry]
}

# --- UNL not active: the node's own verdict that its UNL is unusable (CRITICAL) -
# unl_active comes straight from validator_list.status — the most authoritative
# signal. 0 means the node no longer has an active trusted list (it has stopped,
# or is about to stop, tracking consensus). The day-based alerts above are leading
# indicators; this is the node telling us directly.
resource "google_monitoring_alert_policy" "unl_not_active" {
  project      = module.validator.project_id
  display_name = "XRPL UNL NOT ACTIVE — node's effective validator list is unusable"
  combiner     = "OR"

  conditions {
    display_name = "unl_active < 1 (validator_list.status != active)"
    condition_threshold {
      filter          = "metric.type=\"custom.googleapis.com/xrpl/validator/unl_active\" AND resource.type=\"generic_task\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "600s" # 10m avoids a single transient read; status is sticky
      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_MIN"
      }
      trigger { count = 1 }
    }
  }

  notification_channels = local.alert_channels
  severity              = "CRITICAL"
  alert_strategy { auto_close = "86400s" }
  documentation {
    content   = "The validator reports `validator_list.status != active` — its effective UNL is not usable, so it is not tracking consensus on a trusted set. This is the node's own authoritative verdict (more direct than the day-to-expiry alerts). Confirm via the `validators` admin RPC, check peer connectivity to vetted hubs, and execute the UNL break-glass runbook (docs/runbooks/unl-break-glass.md) if no valid list can be obtained over P2P."
    mime_type = "text/markdown"
  }
  depends_on = [google_monitoring_metric_descriptor.unl_active]
}

# --- A publisher list dropped (early redundancy signal) -----------------------
# Both publishers (Ripple + XRPLF) should be `available`. One dropping to
# unavailable is a distinct early signal — the node still runs on the surviving
# list (threshold=1), so this is a WARNING to investigate that publisher's P2P
# refresh, not yet a node-stop. (observability-sre consult, 2026-06-21.)
resource "google_monitoring_alert_policy" "unl_publishers_degraded" {
  project      = module.validator.project_id
  display_name = "XRPL UNL — a publisher list dropped (only 1 of 2 available)"
  combiner     = "OR"

  conditions {
    display_name = "unl_publisher_lists_available < 2"
    condition_threshold {
      filter          = "metric.type=\"custom.googleapis.com/xrpl/validator/unl_publisher_lists_available\" AND resource.type=\"generic_task\""
      comparison      = "COMPARISON_LT"
      threshold_value = 2
      duration        = "600s" # debounce a transient unavailability during a P2P list update
      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_MIN"
      }
      trigger { count = 1 }
    }
  }

  notification_channels = local.alert_channels
  severity              = "WARNING"
  alert_strategy { auto_close = "86400s" }
  documentation {
    content   = "Only one of the two XRPL publisher lists (Ripple `ED2677AB…` / XRPLF `ED42AEC…`) is currently `available` on the node. The validator still tracks consensus on the surviving list (`validator_list_threshold` is satisfied by one), so this is NOT an outage — it is an early signal that one publisher's list stopped refreshing over P2P. Check the `validators` admin RPC `publisher_lists[]` and peer connectivity to vetted hubs. If the surviving list also approaches expiry (`unl_max_expiry`), escalate to the break-glass runbook (docs/runbooks/unl-break-glass.md)."
    mime_type = "text/markdown"
  }
  depends_on = [google_monitoring_metric_descriptor.unl_publisher_lists_available]
}

# --- NOT PROPOSING: the validator stopped participating (PAGE) -----------------
# Implements observability-baseline.md canon ("page on server_state != proposing
# for > 5 min") — deferred at Pass 1 because only log-based metrics existed; the
# sidecar now emits the `proposing` GAUGE (1=proposing, 0=not), so it is buildable.
# This is the REAL validation SLO: a non-proposing node is not validating and UNL
# curators score it down — distinct from validator_stuck (no consensus lines) and
# from peer_count (a node can be thin-peered yet still proposing — observed steady
# state). Design (observability-sre consult, 2026-06-30):
#   ALIGN_MEAN over 300s + LT 0.5 + duration 60s. MEAN absorbs transient single ~30s
#   0-blips (3 observed harmless over 7d → mean ~0.9, no fire); NOT ALIGN_MIN, which
#   AMPLIFIES a blip (one 0 collapses the window). duration 60s, NOT 0s: GCP rejects
#   duration 0 whenever evaluation_missing_data is set (Error 400 "must have a non-zero
#   duration" — hit at apply 2026-06-30). 60s is the minimum non-zero; fires on the first
#   sustained sub-0.5 5-min window → worst-case onset→page ~5-8 min, matching the canon
#   "page on not-proposing > 5 min". (300s would push worst case to ~12.5 min for no
#   false-fire benefit — the MEAN aligner already debounces blips.) Catches the
#   #7572 stuck-in-`connected` signature → automated backstop to the manual sync-soak
#   gate (docs/runbooks/validator-recreate.md).
# evaluation_missing_data INACTIVE: a full metric GAP — incl. a normal ~2min recreate,
# where the sidecar co-dies with rippled — is owned by poller_down, NOT scored as 0s
# here; this policy judges value only when data is present (no false page, no double-fire).
resource "google_monitoring_alert_policy" "validator_not_proposing" {
  project      = module.validator.project_id
  display_name = "XRPL validator NOT PROPOSING — stopped participating (5m)"
  combiner     = "OR"
  # paging policy → omit severity (repo convention; see validator_down et al.)

  conditions {
    display_name = "proposing 5m-mean < 0.5 (mostly non-proposing in the window)"
    condition_threshold {
      filter                  = "metric.type=\"custom.googleapis.com/xrpl/validator/proposing\" AND resource.type=\"generic_task\""
      comparison              = "COMPARISON_LT"
      threshold_value         = 0.5                                # 0/1 GAUGE; LT-0.5 = "5m mean below half" (matches amendment_blocked idiom)
      duration                = "60s"                              # min non-zero; GCP rejects 0s when evaluation_missing_data is set. ~5-8m worst-case page; MEAN debounces blips
      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE" # gaps → poller_down, not here
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN" # absorbs ~30s 0-blips + a ~2min recreate; NOT ALIGN_MIN
      }
      trigger { count = 1 }
    }
  }

  notification_channels = local.alert_channels
  alert_strategy { auto_close = "1800s" }
  documentation {
    content   = "The 5-minute average of the validator's `proposing` signal dropped below 0.5 (non-proposing for the majority of a 5-minute window) — `server_state` is no longer `proposing`, so the node is NOT validating (UNL curators score this down). A normal ~2min clock-safe recreate will NOT trigger this (the metric gaps during the reboot and is ignored). If this fired DURING/after a recreate and the node is stuck in `connected` with `complete_ledgers` not advancing, that is the #7572 signature — follow the FAIL path in docs/runbooks/validator-recreate.md (roll back to the pre-recreate snapshot). Otherwise check `server_state` via the localhost admin RPC and peer/UNL health."
    mime_type = "text/markdown"
  }
  depends_on = [google_monitoring_metric_descriptor.proposing]
}

# --- LOW PEERS: dropped below the structural floor (WARNING, visibility-only) --
# Deliberate deviation from observability-baseline.md canon, which lists
# "peer count < 3" under PAGE. For THIS validator that is alert-debt: with
# peer_private=1 (no discovery), [ips_fixed] IS the entire outbound set, only ~5
# citable public hubs exist, and ~2 are reliably up — so 2 peers is the structural
# EQUILIBRIUM, not an incident, while agreement holds at 99.96%. Page the OUTCOME
# (validator_not_proposing), warn on peers. Captured as cs-ledger-feedback against
# the canon. Threshold 1.5 (NOT 3): equilibrium 2 < 3 would leave this policy
# PERMANENTLY OPEN (auto_close reopens daily) and train the channel to be ignored
# (observability-sre, 2026-06-30). 1.5 fires only on a SUSTAINED drop to a single
# peer (SPOF per peer-set-curation canon) or zero. The "below ideal ≥8" health
# view lives on the dashboard, not a perpetually-firing policy.
# NOTE: `severity = WARNING` is an incident-classification LABEL, not a routing
# gate — Cloud Monitoring fans EVERY policy to notification_channels regardless of
# severity. Harmless today (channels are email+slack, no real pager); if a true
# pager channel is ever added, SPLIT channels so peer noise stays off it.
resource "google_monitoring_alert_policy" "validator_low_peers" {
  project      = module.validator.project_id
  display_name = "XRPL validator LOW PEERS — below the 2-peer floor (WARNING)"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "peer_count mean < 1.5 over 5m, sustained 5m"
    condition_threshold {
      filter                  = "metric.type=\"custom.googleapis.com/xrpl/validator/peer_count\" AND resource.type=\"generic_task\""
      comparison              = "COMPARISON_LT"
      threshold_value         = 1.5 # equilibrium is 2; 1.5 fires only on sustained drop to 1/0 (NOT 3 → that perma-fires)
      duration                = "300s"
      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN" # one transient 1 among 2s → mean 1.9, no fire
      }
      trigger { count = 1 }
    }
  }

  notification_channels = local.alert_channels
  alert_strategy { auto_close = "86400s" }
  documentation {
    content   = "The validator's connected peer count dropped below the 2-peer structural floor (to a single peer or zero) for 5+ minutes. A single peer is a SPOF for both ledger sync and validation relay (peer-set-curation canon). This is a WARNING, not a page — the paging signal is validator_not_proposing. Check the `peers` admin RPC and reachability of the pinned [ips_fixed] hubs (r.ripple.com, hub.xrpl-commons.org, sahyadri.isrdc.in, hubs.xrpkuwait.com, zaphod.alloy.ee). The durable fix to reach the ≥8 target is a CS-operated peer node (public-hub pinning is exhausted)."
    mime_type = "text/markdown"
  }
  depends_on = [google_monitoring_metric_descriptor.peer_count]
}
