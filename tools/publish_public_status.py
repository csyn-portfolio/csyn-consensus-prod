#!/usr/bin/env python3
"""Publish validator public status JSON from OUR Cloud Monitoring sidecar metrics.

Reads custom.googleapis.com/xrpl/validator/* written by the on-VM sidecar
(localhost admin RPC → Monitoring over restricted VIP). Writes:

  gs://csyn-www-validator1-toml/status.json
  gs://csyn-www-validator1-toml/history.json

No XRPScan. No private fields beyond what the sidecar already emits publicly
as gauges (proposing, peers, amendment_blocked, UNL gauges, heartbeat).

Auth: application-default / gcloud user credentials with monitoring.timeSeries.list
on csyn-ldg-validator-prod and storage.objectAdmin on the www bucket (or use
gcloud storage cp after writing local files with --local-only).

Usage:
  python3 tools/publish_public_status.py
  python3 tools/publish_public_status.py --local-dir /tmp/v1-status
  python3 tools/publish_public_status.py --upload
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROJECT = "csyn-ldg-validator-prod"
BUCKET = "csyn-www-validator1-toml"
METRIC_PREFIX = "custom.googleapis.com/xrpl/validator"
# Public XRPL validator master key (published on-chain / explorers) — not a secret.
PUBLIC_VALIDATOR_MASTER_KEY = (
    "nHUQEd51hNxF3vdVHJKewxZUzXqiP78agDL2bVSiA7Ja4dRFZUGq"  # gitleaks:allow
)
DOMAIN = "validator1.cloudsyndicate.io"


def access_token() -> str:
    out = subprocess.check_output(
        ["gcloud", "auth", "print-access-token"], text=True
    ).strip()
    if not out:
        raise SystemExit("empty access token — run gcloud auth login")
    return out


def monitoring_get(token: str, metric: str, start: datetime, end: datetime,
                   align_seconds: int | None = None) -> list:
    filt = f'metric.type="{METRIC_PREFIX}/{metric}"'
    q = {
        "filter": filt,
        "interval.startTime": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "interval.endTime": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pageSize": "100",
    }
    if align_seconds:
        q["aggregation.alignmentPeriod"] = f"{align_seconds}s"
        q["aggregation.perSeriesAligner"] = "ALIGN_MEAN"
        q["aggregation.crossSeriesReducer"] = "REDUCE_MEAN"
        q["aggregation.groupByFields"] = "resource.label.task_id"
    url = (
        f"https://monitoring.googleapis.com/v3/projects/{PROJECT}/timeSeries?"
        + urllib.parse.urlencode(q)
    )
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.load(resp)
    return data.get("timeSeries", [])


def latest_value(series: list) -> float | None:
    if not series:
        return None
    pts = series[0].get("points") or []
    if not pts:
        return None
    v = pts[0].get("value") or {}
    if "doubleValue" in v:
        return float(v["doubleValue"])
    if "int64Value" in v:
        return float(v["int64Value"])
    return None


def history_points(series: list) -> list[dict]:
    if not series:
        return []
    pts = series[0].get("points") or []
    out = []
    for p in pts:
        v = p.get("value") or {}
        val = v.get("doubleValue", v.get("int64Value"))
        if val is None:
            continue
        ts = (p.get("interval") or {}).get("endTime") or (p.get("interval") or {}).get(
            "startTime"
        )
        out.append({"t": ts, "v": float(val)})
    # Monitoring returns newest first; chart wants oldest first
    out.reverse()
    return out


def version_from_logs(token: str) -> str | None:
    """Best-effort: recent gcplogs mentioning build / 3.3.x."""
    # Use gcloud logging — more reliable filter language than raw API here
    try:
        out = subprocess.check_output(
            [
                "gcloud",
                "logging",
                "read",
                'resource.type="gce_instance" AND (textPayload:"3.3." OR textPayload:"build_version" OR textPayload:"Version is")',
                f"--project={PROJECT}",
                "--limit=10",
                "--format=value(textPayload)",
                "--freshness=14d",
            ],
            text=True,
            timeout=90,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    for line in out.splitlines():
        if "3.3." in line:
            # grab first 3.3.x token
            for part in line.replace(",", " ").split():
                if part.startswith("3.3."):
                    return part.strip("\"'")
            if "3.3.0" in line:
                return "3.3.0"
    return None


def build_status(token: str) -> tuple[dict, dict]:
    now = datetime.now(timezone.utc)
    start_short = now - timedelta(hours=2)
    start_hist = now - timedelta(days=7)

    metrics = {}
    for name in (
        "proposing",
        "peer_count",
        "amendment_blocked",
        "unl_active",
        "poller_heartbeat",
        "unl_min_days_to_expiry",
        "unl_max_days_to_expiry",
        "unl_publisher_lists_available",
        "amendments_in_majority_window",
    ):
        series = monitoring_get(token, name, start_short, now)
        metrics[name] = latest_value(series)

    peer_hist = history_points(
        monitoring_get(token, "peer_count", start_hist, now, align_seconds=3600)
    )
    prop_hist = history_points(
        monitoring_get(token, "proposing", start_hist, now, align_seconds=3600)
    )

    ver_log = version_from_logs(token)
    # Fallback: prod cutover to 3.3.0 recorded in TASKS (2026-08-08); logs filter can miss.
    ver = ver_log or "3.3.0"
    ver_source = "gcplogs" if ver_log else "deploy_record_3.3.0"

    proposing = metrics.get("proposing")
    status = {
        "schema": "csyn-validator-public-status/v1",
        "source": "cloud-monitoring-sidecar",
        "source_detail": (
            "Sidecar on the validator VM reads localhost admin RPC and writes "
            "custom.googleapis.com/xrpl/validator/* gauges. This file is a public "
            "snapshot of those series — not XRPScan."
        ),
        "published_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "domain": DOMAIN,
        "master_key": PUBLIC_VALIDATOR_MASTER_KEY,
        "network": "mainnet",
        "version": ver,
        "version_source": ver_source,
        "server_state": "proposing"
        if proposing == 1.0
        else ("connected" if proposing == 0.0 else "unknown"),
        "proposing": proposing == 1.0 if proposing is not None else None,
        "amendment_blocked": metrics.get("amendment_blocked") == 1.0
        if metrics.get("amendment_blocked") is not None
        else None,
        "peer_count": int(metrics["peer_count"])
        if metrics.get("peer_count") is not None
        else None,
        "unl_active": metrics.get("unl_active") == 1.0
        if metrics.get("unl_active") is not None
        else None,
        "unl_min_days_to_expiry": metrics.get("unl_min_days_to_expiry"),
        "unl_max_days_to_expiry": metrics.get("unl_max_days_to_expiry"),
        "unl_publisher_lists_available": metrics.get("unl_publisher_lists_available"),
        "amendments_in_majority_window": metrics.get("amendments_in_majority_window"),
        "sidecar_heartbeat": metrics.get("poller_heartbeat") == 1.0
        if metrics.get("poller_heartbeat") is not None
        else None,
        "metrics_fresh": metrics.get("poller_heartbeat") == 1.0,
    }

    history = {
        "schema": "csyn-validator-public-history/v1",
        "source": "cloud-monitoring-sidecar",
        "published_at": status["published_at"],
        "alignment": "1h mean",
        "window_days": 7,
        "series": {
            "peer_count": peer_hist,
            "proposing": prop_hist,
        },
    }
    return status, history


def upload_gcs(local: Path, object_name: str, content_type: str) -> None:
    subprocess.check_call(
        [
            "gcloud",
            "storage",
            "cp",
            str(local),
            f"gs://{BUCKET}/{object_name}",
            f"--content-type={content_type}",
            "--cache-control=public, max-age=60",
        ]
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--local-dir", type=Path, default=Path("/tmp/csyn-v1-status"))
    ap.add_argument("--upload", action="store_true", help=f"Upload to gs://{BUCKET}/")
    args = ap.parse_args()
    args.local_dir.mkdir(parents=True, exist_ok=True)

    token = access_token()
    status, history = build_status(token)

    status_path = args.local_dir / "status.json"
    history_path = args.local_dir / "history.json"
    status_path.write_text(json.dumps(status, indent=2) + "\n")
    history_path.write_text(json.dumps(history, indent=2) + "\n")
    print(f"wrote {status_path}")
    print(f"wrote {history_path}")
    print(
        json.dumps(
            {
                k: status[k]
                for k in (
                    "version",
                    "server_state",
                    "proposing",
                    "peer_count",
                    "amendment_blocked",
                    "unl_active",
                    "published_at",
                )
            },
            indent=2,
        )
    )

    if args.upload:
        upload_gcs(status_path, "status.json", "application/json")
        upload_gcs(history_path, "history.json", "application/json")
        print(f"uploaded gs://{BUCKET}/status.json and history.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
