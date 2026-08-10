#!/usr/bin/env python3
"""Publish validator public status from OUR Cloud Monitoring sidecar metrics.

Accuracy:
  - Latest gauges: raw points only (no aligner) + per-metric sample timestamps.
  - Freshness = age of newest core sample (proposing/peers/heartbeat), not
    heartbeat boolean alone. Threshold: FRESH_SECONDS (120).
  - Version: deploy pin by default (no sidecar version metric today). Optional
    gcplogs probe never invents a version from third parties.
  - History: 7d hourly ALIGN_MEAN — peers = mean peer count; proposing = mean
    of 0/1 gauge ≈ fraction of each hour spent proposing.

Performance:
  - Parallel Monitoring fetches (thread pool).
  - Latest window 10m, pageSize=1 (only need newest point).
  - History pageSize=200 (≤168 hourly points for 7d).
  - Version logs OFF by default (was ~25s wall with zero hit rate).

Writes:
  gs://csyn-www-validator1-toml/status.json
  gs://csyn-www-validator1-toml/history.json

Usage:
  python3 tools/publish_public_status.py --upload
  python3 tools/publish_public_status.py --upload --with-version-logs
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROJECT = "csyn-ldg-validator-prod"
BUCKET = "csyn-www-validator1-toml"
METRIC_PREFIX = "custom.googleapis.com/xrpl/validator"
# Public XRPL validator master key (on-chain / explorers) — not a secret.
PUBLIC_VALIDATOR_MASTER_KEY = (
    "nHUQEd51hNxF3vdVHJKewxZUzXqiP78agDL2bVSiA7Ja4dRFZUGq"  # gitleaks:allow
)
DOMAIN = "validator1.cloudsyndicate.io"

# Sidecar writes every ~30s; samples older than this are not "live".
FRESH_SECONDS = 120
# Known pin (prod cutover 2026-08-08). Prefer a future sidecar version gauge.
DEPLOY_PIN_VERSION = "3.3.0"
# How far back to look for the latest raw gauge (sidecar cadence ~30s).
LATEST_LOOKBACK = timedelta(minutes=10)
HISTORY_DAYS = 7
HISTORY_ALIGN_S = 3600

LATEST_METRICS = (
    "proposing",
    "peer_count",
    "amendment_blocked",
    "unl_active",
    "poller_heartbeat",
    "unl_min_days_to_expiry",
    "unl_max_days_to_expiry",
    "unl_publisher_lists_available",
    "amendments_in_majority_window",
)
# Core freshness: these must be recent for metrics_fresh=true.
CORE_METRICS = ("proposing", "peer_count", "poller_heartbeat")


def access_token() -> str:
    out = subprocess.check_output(
        ["gcloud", "auth", "print-access-token"], text=True
    ).strip()
    if not out:
        raise SystemExit("empty access token — run gcloud auth login")
    return out


def _parse_point_value(v: dict) -> float | None:
    if "doubleValue" in v:
        return float(v["doubleValue"])
    if "int64Value" in v:
        return float(v["int64Value"])
    return None


def _parse_rfc3339(ts: str) -> datetime | None:
    """Parse Monitoring RFC3339 timestamps to aware UTC.

    Critical: never produce a naive datetime — on this laptop that would be
    interpreted as America/Chicago and shift sample_time by +5h (CDT).
    """
    if not ts:
        return None
    try:
        s = ts.strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        # Split date / time / offset. Offset sign is after 'T', not date hyphens.
        tpos = s.find("T")
        if tpos < 0:
            return None
        date_part = s[:tpos]
        rest = s[tpos + 1 :]
        sign_at = -1
        for i, ch in enumerate(rest):
            if ch in "+-" and i > 0:
                sign_at = i
                break
        if sign_at >= 0:
            time_part, tz = rest[:sign_at], rest[sign_at:]
        else:
            time_part, tz = rest, "+00:00"
        if "." in time_part:
            hms, frac = time_part.split(".", 1)
            frac = "".join(c for c in frac if c.isdigit())
            frac = (frac + "000000")[:6]
            time_part = f"{hms}.{frac}"
        dt = datetime.fromisoformat(f"{date_part}T{time_part}{tz}")
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except ValueError:
        return None


def _fmt_rfc3339_ms(dt: datetime) -> str:
    dt = dt.astimezone(timezone.utc)
    return (
        dt.strftime("%Y-%m-%dT%H:%M:%S.")
        + f"{dt.microsecond // 1000:03d}Z"
    )


def monitoring_get(
    token: str,
    metric: str,
    start: datetime,
    end: datetime,
    *,
    align_seconds: int | None = None,
    aligner: str = "ALIGN_MEAN",
    page_size: int = 250,
    timeout: float = 20.0,
) -> list:
    filt = f'metric.type="{METRIC_PREFIX}/{metric}"'
    q: dict[str, str] = {
        "filter": filt,
        "interval.startTime": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "interval.endTime": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pageSize": str(page_size),
        "view": "FULL",
    }
    if align_seconds:
        q["aggregation.alignmentPeriod"] = f"{align_seconds}s"
        q["aggregation.perSeriesAligner"] = aligner
    url = (
        f"https://monitoring.googleapis.com/v3/projects/{PROJECT}/timeSeries?"
        + urllib.parse.urlencode(q)
    )
    series: list = []
    while url:
        data = None
        last_err: Exception | None = None
        for attempt in range(4):
            req = urllib.request.Request(
                url, headers={"Authorization": f"Bearer {token}"}
            )
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    data = json.load(resp)
                break
            except urllib.error.HTTPError as e:
                last_err = e
                # 429 / 503: back off; accuracy needs the read to succeed.
                if e.code in (429, 500, 503) and attempt < 3:
                    time.sleep(0.4 * (2**attempt))
                    continue
                raise
        if data is None:
            raise last_err or RuntimeError("monitoring_get failed with no response")
        series.extend(data.get("timeSeries", []))
        token_page = data.get("nextPageToken")
        if not token_page:
            break
        url = (
            f"https://monitoring.googleapis.com/v3/projects/{PROJECT}/timeSeries?"
            + urllib.parse.urlencode({**q, "pageToken": token_page})
        )
    return series


def latest_sample(series: list) -> tuple[float | None, datetime | None]:
    """Return (value, sample_time) from the newest raw point across series."""
    best_val: float | None = None
    best_ts: datetime | None = None
    for s in series:
        for p in s.get("points") or []:
            val = _parse_point_value(p.get("value") or {})
            if val is None:
                continue
            interval = p.get("interval") or {}
            ts = _parse_rfc3339(
                interval.get("endTime") or interval.get("startTime") or ""
            )
            if ts is None:
                continue
            if best_ts is None or ts > best_ts:
                best_ts = ts
                best_val = val
    return best_val, best_ts


def history_points(series: list) -> list[dict]:
    """Merge aligned points from all series; prefer first series if single task."""
    # Sidecar is one series; if multiples appear, take series[0] only to avoid
    # double-counting hourly buckets from distinct resources.
    if not series:
        return []
    pts = series[0].get("points") or []
    out: list[dict] = []
    for p in pts:
        val = _parse_point_value(p.get("value") or {})
        if val is None:
            continue
        interval = p.get("interval") or {}
        ts = interval.get("endTime") or interval.get("startTime")
        out.append({"t": ts, "v": round(float(val), 4)})
    out.reverse()  # oldest first
    return out


def version_from_logs() -> tuple[str | None, str | None]:
    """Optional log probe. Bounded hard — prefer deploy pin on timeout/miss."""
    try:
        out = subprocess.check_output(
            [
                "gcloud",
                "logging",
                "read",
                'resource.type="gce_instance" AND '
                '(textPayload:"build_version" OR textPayload:"rippled-3.")',
                f"--project={PROJECT}",
                "--limit=5",
                "--format=value(timestamp,textPayload)",
                "--freshness=3d",
                "--order=desc",
            ],
            text=True,
            timeout=8,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return None, None

    for line in out.splitlines():
        payload = line.split("\t", 1)[-1] if "\t" in line else line
        for part in payload.replace(",", " ").replace('"', " ").split():
            token = part.strip()
            if token.startswith("rippled-") and len(token) > 8:
                ver = token.replace("rippled-", "", 1)
                if ver[0:1].isdigit() and ver.count(".") >= 2:
                    return ver, payload[:160]
            if (
                len(token) >= 5
                and token[0].isdigit()
                and token.count(".") >= 2
                and all(c.isdigit() or c == "." for c in token)
            ):
                return token, payload[:160]
    return None, None


def build_status(token: str, *, with_version_logs: bool) -> tuple[dict, dict, dict]:
    t0 = time.perf_counter()
    now = datetime.now(timezone.utc)
    start_latest = now - LATEST_LOOKBACK
    start_hist = now - timedelta(days=HISTORY_DAYS)
    timings: dict[str, float] = {}

    def fetch_latest(name: str):
        t = time.perf_counter()
        # pageSize=1: Monitoring returns newest first for unaligned series.
        series = monitoring_get(
            token, name, start_latest, now, page_size=1, timeout=15.0
        )
        val, sample_ts = latest_sample(series)
        return name, val, sample_ts, time.perf_counter() - t

    def fetch_hist(name: str, aligner: str):
        t = time.perf_counter()
        series = monitoring_get(
            token,
            name,
            start_hist,
            now,
            align_seconds=HISTORY_ALIGN_S,
            aligner=aligner,
            page_size=200,
            timeout=25.0,
        )
        return name, history_points(series), time.perf_counter() - t

    metrics: dict[str, float | None] = {}
    sample_times: dict[str, datetime | None] = {}
    peer_hist: list = []
    prop_hist: list = []

    with ThreadPoolExecutor(max_workers=12) as pool:
        latest_futs = [pool.submit(fetch_latest, n) for n in LATEST_METRICS]
        hist_peer = pool.submit(fetch_hist, "peer_count", "ALIGN_MEAN")
        hist_prop = pool.submit(fetch_hist, "proposing", "ALIGN_MEAN")
        for fut in as_completed(latest_futs):
            name, val, sample_ts, dt = fut.result()
            metrics[name] = val
            sample_times[name] = sample_ts
            timings[f"latest.{name}"] = round(dt, 3)
        _, peer_hist, dt_p = hist_peer.result()
        _, prop_hist, dt_pr = hist_prop.result()
        timings["hist.peer_count"] = round(dt_p, 3)
        timings["hist.proposing"] = round(dt_pr, 3)

    t_ver = time.perf_counter()
    if with_version_logs:
        ver_log, ver_evidence = version_from_logs()
    else:
        ver_log, ver_evidence = None, None
    timings["version_logs"] = round(time.perf_counter() - t_ver, 3)

    if ver_log:
        ver, ver_source = ver_log, "gcplogs"
    else:
        ver, ver_source = DEPLOY_PIN_VERSION, "deploy_pin"
        ver_evidence = (
            f"Pin {DEPLOY_PIN_VERSION} (prod cutover 2026-08-08). "
            "No sidecar version metric; optional --with-version-logs found none."
            if not with_version_logs
            else (
                f"No log match; pin {DEPLOY_PIN_VERSION} "
                "(prod cutover 2026-08-08)."
            )
        )

    core_ts = [sample_times[k] for k in CORE_METRICS if sample_times.get(k)]
    newest = max(core_ts) if core_ts else None
    age_s = (now - newest).total_seconds() if newest else None
    # Negative age = clock skew or parse bug; never report as "fresh".
    if age_s is not None and age_s < 0:
        age_s = 0.0
    metrics_fresh = (
        age_s is not None
        and 0 <= age_s <= FRESH_SECONDS
        and all(sample_times.get(k) is not None for k in CORE_METRICS)
    )

    proposing = metrics.get("proposing")
    peers = metrics.get("peer_count")
    peer_out = int(round(peers)) if peers is not None else None

    status = {
        "schema": "csyn-validator-public-status/v2",
        "source": "cloud-monitoring-sidecar",
        "source_detail": (
            "Sidecar on the validator VM reads localhost admin RPC and writes "
            "custom.googleapis.com/xrpl/validator/* gauges. Public snapshot of "
            "those series — not third-party explorers."
        ),
        "published_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sample_time": _fmt_rfc3339_ms(newest) if newest else None,
        "sample_age_seconds": round(age_s, 1) if age_s is not None else None,
        "metrics_fresh": metrics_fresh,
        "fresh_threshold_seconds": FRESH_SECONDS,
        "domain": DOMAIN,
        "master_key": PUBLIC_VALIDATOR_MASTER_KEY,
        "network": "mainnet",
        "version": ver,
        "version_source": ver_source,
        "version_evidence": ver_evidence,
        "server_state": "proposing"
        if proposing == 1.0
        else ("connected" if proposing == 0.0 else "unknown"),
        "proposing": proposing == 1.0 if proposing is not None else None,
        "amendment_blocked": metrics.get("amendment_blocked") == 1.0
        if metrics.get("amendment_blocked") is not None
        else None,
        "peer_count": peer_out,
        "unl_active": metrics.get("unl_active") == 1.0
        if metrics.get("unl_active") is not None
        else None,
        "unl_min_days_to_expiry": round(metrics["unl_min_days_to_expiry"], 3)
        if metrics.get("unl_min_days_to_expiry") is not None
        else None,
        "unl_max_days_to_expiry": round(metrics["unl_max_days_to_expiry"], 3)
        if metrics.get("unl_max_days_to_expiry") is not None
        else None,
        "unl_publisher_lists_available": int(
            round(metrics["unl_publisher_lists_available"])
        )
        if metrics.get("unl_publisher_lists_available") is not None
        else None,
        "amendments_in_majority_window": int(
            round(metrics["amendments_in_majority_window"])
        )
        if metrics.get("amendments_in_majority_window") is not None
        else None,
        "sidecar_heartbeat": metrics.get("poller_heartbeat") == 1.0
        if metrics.get("poller_heartbeat") is not None
        else None,
    }

    history = {
        "schema": "csyn-validator-public-history/v2",
        "source": "cloud-monitoring-sidecar",
        "published_at": status["published_at"],
        "alignment": {
            "peer_count": f"{HISTORY_ALIGN_S}s ALIGN_MEAN",
            "proposing": f"{HISTORY_ALIGN_S}s ALIGN_MEAN (≈ fraction of hour proposing)",
        },
        "window_days": HISTORY_DAYS,
        "series": {"peer_count": peer_hist, "proposing": prop_hist},
        "point_counts": {
            "peer_count": len(peer_hist),
            "proposing": len(prop_hist),
        },
    }

    timings["total_build"] = round(time.perf_counter() - t0, 3)
    return status, history, timings


def upload_gcs(local: Path, object_name: str, content_type: str) -> None:
    subprocess.check_call(
        [
            "gcloud",
            "storage",
            "cp",
            str(local),
            f"gs://{BUCKET}/{object_name}",
            f"--content-type={content_type}",
            # Short cache: accuracy over edge stickiness
            "--cache-control=public, max-age=30",
        ]
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--local-dir", type=Path, default=Path("/tmp/csyn-v1-status"))
    ap.add_argument("--upload", action="store_true")
    ap.add_argument(
        "--with-version-logs",
        action="store_true",
        help="Probe Cloud Logging for build_version (slow; off by default)",
    )
    # Keep alias so existing runbooks/schedulers do not break.
    ap.add_argument(
        "--no-version-logs",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    args = ap.parse_args()
    args.local_dir.mkdir(parents=True, exist_ok=True)

    t0 = time.perf_counter()
    token = access_token()
    status, history, timings = build_status(
        token, with_version_logs=args.with_version_logs and not args.no_version_logs
    )
    timings["total_wall"] = round(time.perf_counter() - t0, 3)

    status_path = args.local_dir / "status.json"
    history_path = args.local_dir / "history.json"
    status_path.write_text(json.dumps(status, indent=2) + "\n")
    history_path.write_text(json.dumps(history, indent=2) + "\n")

    print(f"wrote {status_path}")
    print(f"wrote {history_path}")
    print(
        json.dumps(
            {
                "version": status["version"],
                "version_source": status["version_source"],
                "server_state": status["server_state"],
                "proposing": status["proposing"],
                "peer_count": status["peer_count"],
                "sample_time": status["sample_time"],
                "sample_age_seconds": status["sample_age_seconds"],
                "metrics_fresh": status["metrics_fresh"],
                "history_points": history["point_counts"],
                "timings_s": timings,
            },
            indent=2,
        )
    )

    if args.upload:
        t_up = time.perf_counter()
        upload_gcs(status_path, "status.json", "application/json")
        upload_gcs(history_path, "history.json", "application/json")
        print(
            f"uploaded gs://{BUCKET}/{{status,history}}.json "
            f"in {time.perf_counter() - t_up:.2f}s"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
