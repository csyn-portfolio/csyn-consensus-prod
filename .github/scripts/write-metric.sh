#!/usr/bin/env bash
# Write one GAUGE point to a custom Cloud Monitoring metric on the validator project.
#
# Extracted from network-visibility.yml because two steps write points and an
# inlined heredoc duplicated in both is how the two resource labels drift apart —
# and if they drift, the heartbeat and the verdict land on different series and the
# dark-probe alert silently stops describing the probe that writes the verdict.
#
# Usage: write-metric.sh <metric-short-name> <double-value>
# Requires: PROJECT_ID, METRIC_LOCATION in the environment; an authenticated gcloud.

set -euo pipefail

METRIC="${1:?metric short name required}"
VALUE="${2:?value required}"

case "$METRIC" in
  network_sees_us | network_sees_us_heartbeat) : ;;
  *) echo "refusing to write unknown metric '$METRIC'" >&2; exit 1 ;;
esac
case "$VALUE" in
  0 | 1) : ;;
  *) echo "refusing to write non-boolean value '$VALUE'" >&2; exit 1 ;;
esac

: "${PROJECT_ID:?PROJECT_ID required}"
: "${METRIC_LOCATION:?METRIC_LOCATION required}"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The resource labels are the series identity. Both metrics MUST use the same set,
# or the dark-probe alert would be watching a different task than the one producing
# verdicts. That is why this lives in one file.
cat > /tmp/ts.json <<JSON
{"timeSeries":[{
  "metric":{"type":"custom.googleapis.com/xrpl/validator/${METRIC}"},
  "resource":{"type":"generic_task","labels":{
    "project_id":"${PROJECT_ID}","location":"${METRIC_LOCATION}",
    "namespace":"xrpl-validator","job":"network-visibility","task_id":"github-actions"}},
  "points":[{"interval":{"endTime":"${NOW}"},"value":{"doubleValue":${VALUE}}}]
}]}
JSON

curl -sS --fail-with-body -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d @/tmp/ts.json \
  "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/timeSeries"

echo "wrote ${METRIC}=${VALUE} at ${NOW}"
