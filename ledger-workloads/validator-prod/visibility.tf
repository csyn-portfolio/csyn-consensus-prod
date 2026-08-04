# visibility.tf — EXTERNAL validation visibility.
#
# Every other alert in this root reads an ON-BOX signal (server_info, validators,
# amendments via the sidecar). All 12 were green throughout the 2026-08-04
# scanner-invisibility investigation, and none *could* have fired, because nothing
# asserts that the NETWORK still receives our validations. This closes that gap.
#
# Written by .github/workflows/network-visibility.yml, NOT by the on-VM sidecar.
# The validator cannot run this check itself: the VPC egress deny-floor permits
# only tcp:51235 and tcp:443 to the restricted VIP, which is also why the original
# public-API Cloud Run poller was retired (see sidecar.tf header). GitHub Actions
# already holds a WIF identity for this repo and has internet, so it is the runner.
#
# Metric semantics (the workflow enforces these):
#   1 = SEEN on >= 2 independent public validation feeds
#   0 = NOT SEEN while >= 2 feeds were carrying untrusted validations
#   no point written = INCONCLUSIVE (script exit 2)
# INCONCLUSIVE writes NOTHING rather than 0. A feed relaying trusted-only in a
# given window cannot show an untrusted validator, so a 0 there would be a lie and
# would page routinely.
#
# TWO metrics, because one cannot answer both questions. `network_sees_us` is
# sparse by design (inconclusive runs write nothing), so ABSENCE of that series is
# ambiguous: it means either "the run was inconclusive" or "nothing is running at
# all". A policy that treats absence as healthy is silent in the second case — which
# is the 2026-08-04 blind spot rebuilt one layer up, with the checker itself dark.
# So the workflow ALSO writes `network_sees_us_heartbeat` = 1 on EVERY run,
# whatever the probe returned, and a separate MetricAbsence policy fires when that
# stops arriving. Sparse-by-design series need a liveness signal that is not sparse.
#
# ACCEPTED RISK (Pete, 2026-08-04): the workflow writes these points as
# `ledger-apply@csyn-platform`, which holds roles/owner on this project — an
# unattended schedule assuming an owner-privileged identity every 30 minutes to
# write one number. Shipped knowingly to close the blind spot sooner; a dedicated
# roles/monitoring.metricWriter identity is the correct shape and is tracked in
# TASKS.md as a follow-up. This comment exists so the next reader finds a decision
# rather than an oversight.

resource "google_monitoring_metric_descriptor" "network_sees_us" {
  project      = module.validator.project_id
  type         = "custom.googleapis.com/xrpl/validator/network_sees_us"
  metric_kind  = "GAUGE"
  value_type   = "DOUBLE"
  unit         = "1"
  display_name = "XRPL validator seen by the network (1=seen on >=2 feeds)"
  description  = "1.0 when our validations were observed on >= 2 independent public validation feeds; 0.0 when >= 2 feeds carried untrusted validations and none showed us. No point is written for an inconclusive run."
}

# WARNING, not PAGE. `validator_not_proposing` already pages for the validating
# outcome itself; this is the weaker, slower external corroboration. It must also
# tolerate the honest noise floor: relay of an UNTRUSTED validator's validations to
# any given observer is intermittent by design (rippled drops untrusted validations
# under load, and `[relay_validations]` may be trusted-only), so a single 0 means
# little. 5400s of sustained 0 is ~3 consecutive runs at the 30-minute cadence.
#
# Do NOT re-implement this by scraping xrpscan/VHS. That design would have fired a
# 63-hour false alarm on 2026-08-01 while the validator was healthy — see TASKS.md
# "Scanner-invisibility investigation".
resource "google_monitoring_alert_policy" "network_visibility_lost" {
  project      = module.validator.project_id
  display_name = "XRPL validator NOT SEEN by the network (external, sustained)"
  combiner     = "OR"

  conditions {
    display_name = "WARN: network has not seen our validations (sustained)"
    condition_threshold {
      filter          = "metric.type=\"custom.googleapis.com/xrpl/validator/network_sees_us\" AND resource.type=\"generic_task\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "5400s"
      aggregations {
        alignment_period   = "1800s"
        per_series_aligner = "ALIGN_MAX" # any SEEN in the window clears it
      }
      trigger { count = 1 }
      # A gap is an inconclusive or skipped run, never an outage.
      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = local.alert_channels
  severity              = "WARNING"
  alert_strategy { auto_close = "86400s" }
  documentation {
    content   = "Our validations have NOT been observed on >= 2 independent public validation feeds for a sustained window, while those feeds WERE carrying untrusted validations (so the absence is meaningful, not a trusted-only window). This does not by itself mean the node is down — check the on-box signals first, which page separately.\n\n**Order of checks:**\n1. `proposing` and `peer_count` alerts — if either is also firing, this is a node problem and they are the primary signal.\n2. Reproduce locally: `node tools/network-sees-validator.mjs --seconds 70`. Exit 2 is INCONCLUSIVE, not an outage — re-run up to 3 times widening `--seconds`.\n3. **Most likely false positive: a rotated validator token.** The check matches the ephemeral signing key. After any `create_token`/manifest rotation, read `.ephemeral_key` from the `validator_info` admin RPC and set it as the repo variable **`VALIDATOR_SIGNING_KEY`** — that is what the every-30-minutes SCHEDULE reads. The `signing_key` dispatch input fixes one manual run only; using it alone leaves the schedule on the stale key and this alert firing indefinitely while the node is perfectly healthy.\n4. On-box confirm via IAP: `server_state` must be `proposing` and `pubkey_validator` must equal our master key.\n5. If the node is healthy and the network genuinely does not carry us, the suspect is peer topology/relay, not the registries. Runbook: docs/runbooks/validator-recreate.md.\n\n**A real but INTERMITTENT problem can also stay under this policy.** The duration accumulates only across contiguous below-threshold windows, and an inconclusive run writes no point, so an alternating `0, inconclusive, 0, inconclusive` pattern can keep resetting the sustained-0 clock. That is the deliberate price of never writing a 0 we cannot justify — but it means a quiet policy is a weaker statement than it looks.\n\n**Silence from THIS policy is not evidence that the network sees us** — the series is sparse by design, so a quiet policy can also mean inconclusive runs. Liveness of the check itself is a separate alert (`XRPL validator visibility probe is DARK`); if that one is quiet too, the check is running.\n\n**Registries (xrpscan/VHS) are NOT evidence here** and must not be used to confirm or deny this alert — see TASKS.md \"Scanner-invisibility investigation\"."
    mime_type = "text/markdown"
  }
  depends_on = [google_monitoring_metric_descriptor.network_sees_us]
}

# --- Probe liveness ------------------------------------------------------------
# Written on EVERY run of network-visibility.yml regardless of probe outcome, so
# the series is dense even when `network_sees_us` is not. Its only job is to prove
# the checker ran.
resource "google_monitoring_metric_descriptor" "network_sees_us_heartbeat" {
  project      = module.validator.project_id
  type         = "custom.googleapis.com/xrpl/validator/network_sees_us_heartbeat"
  metric_kind  = "GAUGE"
  value_type   = "DOUBLE"
  unit         = "1"
  display_name = "XRPL external-visibility probe heartbeat (1 = the probe ran)"
  description  = "1.0 written by .github/workflows/network-visibility.yml on every run, whatever the probe returned — including inconclusive runs that write no network_sees_us point. Absence means the check itself is not running."
}

# MetricAbsence, not a threshold: there is no value to compare, the signal IS
# arrival. 5400s = three missed runs at the 30-minute cadence, so a single skipped
# or slow run does not fire.
#
# This is the policy that makes the visibility alert trustworthy. Without it,
# "no alert" and "no checker" look identical from the outside.
resource "google_monitoring_alert_policy" "network_visibility_probe_dark" {
  project      = module.validator.project_id
  display_name = "XRPL validator visibility probe is DARK (no heartbeat)"
  combiner     = "OR"

  conditions {
    display_name = "WARN: no external-visibility probe heartbeat"
    condition_absent {
      filter   = "metric.type=\"custom.googleapis.com/xrpl/validator/network_sees_us_heartbeat\" AND resource.type=\"generic_task\""
      duration = "5400s"
      aggregations {
        alignment_period   = "1800s"
        per_series_aligner = "ALIGN_COUNT"
      }
      trigger { count = 1 }
    }
  }

  notification_channels = local.alert_channels
  severity              = "WARNING"
  alert_strategy { auto_close = "86400s" }
  documentation {
    content   = "The external-visibility probe has not written a heartbeat for a sustained window, so **nobody is currently checking whether the network can see our validations**. This says nothing about the validator's health — the on-box alerts still cover that — but it means `XRPL validator NOT SEEN by the network` cannot fire, and its silence is meaningless until this is resolved.\n\n**COLD START — read this after any apply.** A MetricAbsence condition may not arm on a series that has never received a point, so immediately after `apply.yml` creates these policies, silence from BOTH of them proves nothing. Dispatch the workflow once by hand (`gh workflow run network-visibility.yml`) and confirm a heartbeat point landed before treating quiet as healthy. This is a required post-apply step, not troubleshooting.\n\n**Check, in order:**\n1. The `network-visibility` workflow in this repo — is it disabled, failing, or has the schedule been dropped? GitHub disables scheduled workflows on repos with no recent activity, which is a real and quiet failure mode.\n2. Its most recent runs: a WIF/auth failure writes no point but may still show as a failed job.\n3. Run it by hand: `gh workflow run network-visibility.yml`.\n4. If the workflow is healthy and points still are not landing, suspect the metric write itself — the run logs carry the Monitoring API response.\n\nDo NOT resolve this by widening the sibling policy's missing-data handling; the two questions are deliberately separate."
    mime_type = "text/markdown"
  }
  depends_on = [google_monitoring_metric_descriptor.network_sees_us_heartbeat]
}
