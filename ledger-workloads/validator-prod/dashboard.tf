# dashboard.tf — single-pane Cloud Monitoring dashboard for the mainnet validator.
# Lays out the 10 on-VM sidecar custom metrics for an at-a-glance health view:
# top-row scorecards (red on trouble), then UNL freshness, then consensus/
# amendments/liveness. Terraform-owned, zero VM touch. All series come from the
# generic_task resource the sidecar writes (custom.googleapis.com/xrpl/validator/*).

locals {
  # Metric type prefix + the shared monitored-resource clause, to keep filters DRY.
  dash_mp  = "custom.googleapis.com/xrpl/validator"
  dash_res = "resource.type=\"generic_task\""
}

resource "google_monitoring_dashboard" "validator" {
  project = module.validator.project_id

  dashboard_json = jsonencode({
    displayName = "XRPL Mainnet Validator — csyn-ldg-validator"
    mosaicLayout = {
      columns = 12
      tiles = [
        # ── Header / how-to-read ────────────────────────────────────────────
        {
          xPos = 0, yPos = 0, width = 12, height = 2
          widget = {
            text = {
              format = "MARKDOWN"
              content = join("\n", [
                "# XRPL Mainnet Validator — `csyn-ldg-validator` (us-south1)",
                "Health from the on-VM **xrpl-sidecar** reading the node's localhost admin RPC every 30s — **zero external egress**.",
                "**Healthy =** Proposing **1** · UNL active **1** · Amendment-blocked **0** · Peers **≥2**. Scorecards turn **red** on trouble.",
                "UNL *days-to-expiry* is the validator-list refresh clock: the node stays trusted until the **latest** list expires (**max days**); **min days** is the early-warning that one publisher's list is going stale.",
                "**External cross-check** (the network's view of us — *not* computable on-node): [xrpscan validator page](https://xrpscan.com/validator/nHUQEd51hNxF3vdVHJKewxZUzXqiP78agDL2bVSiA7Ja4dRFZUGq) · [network amendments](https://xrpscan.com/amendments)"
              ])
            }
          }
        },

        # ── Row 1: at-a-glance health scorecards ────────────────────────────
        {
          xPos = 0, yPos = 2, width = 3, height = 4
          widget = {
            title = "Proposing (1 = participating)"
            scorecard = {
              timeSeriesQuery = { timeSeriesFilter = {
                filter = "metric.type=\"${local.dash_mp}/proposing\" ${local.dash_res}"
                # ALIGN_MIN (not MEAN): a 30s metric over a 60s window averages 2
                # samples, so MEAN turns a single transient 0 into a misleading 0.5
                # half-red. MIN shows a clean 0/1 (worst sample in the window).
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MIN" }
              } }
              sparkChartView = { sparkChartType = "SPARK_LINE" }
              thresholds     = [{ value = 1, color = "RED", direction = "BELOW" }]
            }
          }
        },
        {
          xPos = 3, yPos = 2, width = 3, height = 4
          widget = {
            title = "UNL active (1 = usable)"
            scorecard = {
              timeSeriesQuery = { timeSeriesFilter = {
                filter      = "metric.type=\"${local.dash_mp}/unl_active\" ${local.dash_res}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MIN" } # binary: worst sample in window
              } }
              sparkChartView = { sparkChartType = "SPARK_LINE" }
              thresholds     = [{ value = 1, color = "RED", direction = "BELOW" }]
            }
          }
        },
        {
          xPos = 6, yPos = 2, width = 3, height = 4
          widget = {
            title = "Amendment-blocked (0 = healthy)"
            scorecard = {
              timeSeriesQuery = { timeSeriesFilter = {
                filter      = "metric.type=\"${local.dash_mp}/amendment_blocked\" ${local.dash_res}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MAX" } # bad=1: catch any blocked sample
              } }
              sparkChartView = { sparkChartType = "SPARK_LINE" }
              thresholds     = [{ value = 1, color = "RED", direction = "ABOVE" }]
            }
          }
        },
        {
          xPos = 9, yPos = 2, width = 3, height = 4
          widget = {
            title = "Connected peers"
            scorecard = {
              timeSeriesQuery = { timeSeriesFilter = {
                filter      = "metric.type=\"${local.dash_mp}/peer_count\" ${local.dash_res}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
              } }
              sparkChartView = { sparkChartType = "SPARK_LINE" }
              thresholds = [
                { value = 2, color = "YELLOW", direction = "BELOW" },
                { value = 1, color = "RED", direction = "BELOW" },
              ]
            }
          }
        },

        # ── Section: UNL freshness ──────────────────────────────────────────
        {
          xPos   = 0, yPos = 6, width = 12, height = 1
          widget = { text = { format = "MARKDOWN", content = "### UNL freshness — is the validator list staying fresh? (refreshes over the XRPL peer protocol; no HTTP)" } }
        },
        {
          xPos = 0, yPos = 7, width = 8, height = 5
          widget = {
            title = "UNL days to expiry — earliest vs latest publisher list"
            xyChart = {
              dataSets = [
                {
                  plotType       = "LINE"
                  legendTemplate = "earliest list (min days) — alert <14"
                  timeSeriesQuery = { timeSeriesFilter = {
                    filter      = "metric.type=\"${local.dash_mp}/unl_min_days_to_expiry\" ${local.dash_res}"
                    aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
                  } }
                },
                {
                  plotType       = "LINE"
                  legendTemplate = "latest list (max days) — node-stop horizon, alert <7"
                  timeSeriesQuery = { timeSeriesFilter = {
                    filter      = "metric.type=\"${local.dash_mp}/unl_max_days_to_expiry\" ${local.dash_res}"
                    aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
                  } }
                },
              ]
              yAxis        = { label = "days", scale = "LINEAR" }
              chartOptions = { mode = "COLOR" }
              # NB: xyChart thresholds accept ONLY value (+ label) — they REJECT
              # both `color` and `direction` (those are scorecard-threshold fields).
              thresholds = [
                { value = 14, label = "earliest-list warn (14d)" },
                { value = 7, label = "node-stop critical (7d)" },
              ]
            }
          }
        },
        {
          xPos = 8, yPos = 7, width = 2, height = 5
          widget = {
            title = "Earliest expiry (days)"
            scorecard = {
              timeSeriesQuery = { timeSeriesFilter = {
                filter      = "metric.type=\"${local.dash_mp}/unl_min_days_to_expiry\" ${local.dash_res}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
              } }
              sparkChartView = { sparkChartType = "SPARK_LINE" }
              thresholds = [
                { value = 14, color = "YELLOW", direction = "BELOW" },
                { value = 7, color = "RED", direction = "BELOW" },
              ]
            }
          }
        },
        {
          xPos = 10, yPos = 7, width = 2, height = 5
          widget = {
            title = "Publisher lists available (of 2)"
            scorecard = {
              timeSeriesQuery = { timeSeriesFilter = {
                filter      = "metric.type=\"${local.dash_mp}/unl_publisher_lists_available\" ${local.dash_res}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
              } }
              sparkChartView = { sparkChartType = "SPARK_LINE" }
              thresholds     = [{ value = 1, color = "YELLOW", direction = "BELOW" }]
            }
          }
        },

        # ── Section: consensus / amendments / liveness ──────────────────────
        {
          xPos   = 0, yPos = 12, width = 12, height = 1
          widget = { text = { format = "MARKDOWN", content = "### Amendments & liveness — upgrade clock + sidecar heartbeat" } }
        },
        {
          xPos = 0, yPos = 13, width = 6, height = 5
          widget = {
            title = "Amendment watch — in majority window & gap to 80%"
            xyChart = {
              dataSets = [
                {
                  plotType       = "LINE"
                  legendTemplate = "amendments in majority window (≥1 ⇒ ~2-wk clock)"
                  timeSeriesQuery = { timeSeriesFilter = {
                    filter      = "metric.type=\"${local.dash_mp}/amendments_in_majority_window\" ${local.dash_res}"
                    aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
                  } }
                },
                {
                  plotType       = "LINE"
                  legendTemplate = "nearest amendment gap to threshold (999 = none)"
                  timeSeriesQuery = { timeSeriesFilter = {
                    filter      = "metric.type=\"${local.dash_mp}/min_gap_to_threshold\" ${local.dash_res}"
                    aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
                  } }
                },
              ]
              yAxis        = { label = "count", scale = "LINEAR" }
              chartOptions = { mode = "COLOR" }
            }
          }
        },
        {
          xPos = 6, yPos = 13, width = 3, height = 5
          widget = {
            title = "Connected peers over time"
            xyChart = {
              dataSets = [{
                plotType       = "LINE"
                legendTemplate = "peers"
                timeSeriesQuery = { timeSeriesFilter = {
                  filter      = "metric.type=\"${local.dash_mp}/peer_count\" ${local.dash_res}"
                  aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
                } }
              }]
              yAxis        = { label = "peers", scale = "LINEAR" }
              chartOptions = { mode = "COLOR" }
            }
          }
        },
        {
          xPos = 9, yPos = 13, width = 3, height = 5
          widget = {
            title = "Sidecar heartbeat (1 = alive)"
            scorecard = {
              timeSeriesQuery = { timeSeriesFilter = {
                filter      = "metric.type=\"${local.dash_mp}/poller_heartbeat\" ${local.dash_res}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MIN" } # binary: worst sample in window
              } }
              sparkChartView = { sparkChartType = "SPARK_LINE" }
              thresholds     = [{ value = 1, color = "RED", direction = "BELOW" }]
            }
          }
        },
      ]
    }
  })
}
