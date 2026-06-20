# sidecar.tf — custom metric descriptors written by the on-VM monitoring sidecar.
# The public-API Cloud Run poller (poller.tf) has been retired; these descriptors
# are now populated by the xrpl-sidecar container running on the validator VM itself,
# reading the localhost admin RPC and writing Cloud Monitoring over the restricted VIP.
#
# Three descriptors are MOVED verbatim from the retired poller.tf (same resource labels,
# same type strings — file-move only, not a rename, so no state destroy+recreate):
#   poller_heartbeat, amendments_in_majority_window, min_gap_to_threshold
# Three descriptors are NEW (on-VM server_info gauges):
#   proposing, amendment_blocked, peer_count

# --- Descriptors moved from poller.tf (same resource labels, no address change) ---

resource "google_monitoring_metric_descriptor" "poller_heartbeat" {
  project      = module.validator.project_id
  type         = "custom.googleapis.com/xrpl/validator/poller_heartbeat"
  metric_kind  = "GAUGE"
  value_type   = "DOUBLE"
  unit         = "1"
  display_name = "XRPL agreement poller heartbeat"
  description  = "Written 1.0 on every successful poll cycle; absence => poller down."
}

# Amendment watch. Count of amendments enabled=false with a non-null majority on
# xrpscan — i.e. past 80% and inside the ~2-week activation countdown. >=1 =>
# confirm our xrpld binary supports them before activation (amendment-blocked is
# the silent way validators stop).
resource "google_monitoring_metric_descriptor" "amendments_in_majority_window" {
  project      = module.validator.project_id
  type         = "custom.googleapis.com/xrpl/validator/amendments_in_majority_window"
  metric_kind  = "GAUGE"
  value_type   = "DOUBLE"
  unit         = "1"
  display_name = "XRPL amendments in majority activation window"
  description  = "Count of amendments enabled=false with majority!=null (≈2-week activation clock running)."
}

# Early-warning gauge: nearest not-yet-enabled amendment's (threshold - count),
# sentinel 999 when none voting. Lower => an amendment is closer to 80%.
resource "google_monitoring_metric_descriptor" "min_gap_to_threshold" {
  project      = module.validator.project_id
  type         = "custom.googleapis.com/xrpl/validator/min_gap_to_threshold"
  metric_kind  = "GAUGE"
  value_type   = "DOUBLE"
  unit         = "1"
  display_name = "XRPL nearest amendment gap to 80% threshold"
  description  = "min(threshold - count) over not-yet-enabled amendments; 999 sentinel when none voting."
}

# --- New descriptors: on-VM server_info gauges (sidecar, replacing poller) ------

resource "google_monitoring_metric_descriptor" "proposing" {
  project      = module.validator.project_id
  type         = "custom.googleapis.com/xrpl/validator/proposing"
  metric_kind  = "GAUGE"
  value_type   = "DOUBLE"
  unit         = "1"
  display_name = "XRPL validator proposing (1=proposing)"
  description  = "1.0 when server_state==proposing, else 0.0 (from local server_info)."
}

resource "google_monitoring_metric_descriptor" "amendment_blocked" {
  project      = module.validator.project_id
  type         = "custom.googleapis.com/xrpl/validator/amendment_blocked"
  metric_kind  = "GAUGE"
  value_type   = "DOUBLE"
  unit         = "1"
  display_name = "XRPL validator amendment-blocked (1=blocked)"
  description  = "1.0 when server_info.amendment_blocked is true — node has stopped validating; rollback impossible."
}

resource "google_monitoring_metric_descriptor" "peer_count" {
  project      = module.validator.project_id
  type         = "custom.googleapis.com/xrpl/validator/peer_count"
  metric_kind  = "GAUGE"
  value_type   = "DOUBLE"
  unit         = "1"
  display_name = "XRPL validator peer count"
  description  = "server_info.peers — connected peer count."
}
