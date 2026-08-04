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
# would page routinely. Absence is handled by EVALUATION_MISSING_DATA_INACTIVE.

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
    content   = "Our validations have NOT been observed on >= 2 independent public validation feeds for a sustained window, while those feeds WERE carrying untrusted validations (so the absence is meaningful, not a trusted-only window). This does not by itself mean the node is down — check the on-box signals first, which page separately.\n\n**Order of checks:**\n1. `proposing` and `peer_count` alerts — if either is also firing, this is a node problem and they are the primary signal.\n2. Reproduce locally: `node tools/network-sees-validator.mjs --seconds 70`. Exit 2 is INCONCLUSIVE, not an outage — re-run up to 3 times widening `--seconds`.\n3. **Most likely false positive: a rotated validator token.** The check matches the ephemeral signing key. After any `create_token`/manifest rotation, read `.ephemeral_key` from the `validator_info` admin RPC and update the workflow's `--signing-key`, or every run reports NOT SEEN while the node is perfectly healthy.\n4. On-box confirm via IAP: `server_state` must be `proposing` and `pubkey_validator` must equal our master key.\n5. If the node is healthy and the network genuinely does not carry us, the suspect is peer topology/relay, not the registries. Runbook: docs/runbooks/validator-recreate.md.\n\n**Registries (xrpscan/VHS) are NOT evidence here** and must not be used to confirm or deny this alert — see TASKS.md \"Scanner-invisibility investigation\"."
    mime_type = "text/markdown"
  }
  depends_on = [google_monitoring_metric_descriptor.network_sees_us]
}
