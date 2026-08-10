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
  - Agreement %: network-observer scores from data.xrpl.org (XRPL.org Validator
    History Service) — NOT reproducible from localhost and NOT XRPScan.
    Windows: 1h / 24h / 30d. Daily report series when the API has them; else
    we accumulate agreement_1h snapshots into history.json on each publish.

Performance:
  - Parallel Monitoring fetches (thread pool) + concurrent agreement HTTP.
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
# XRPL.org network observer (agreement scores). Not XRPScan; not our sidecar.
XRPL_ORG_VALIDATORS = "https://data.xrpl.org/v1/network/validators"
XRPL_ORG_VALIDATOR = "https://data.xrpl.org/v1/network/validator/"
XRPL_ORG_REPORTS_SUFFIX = "/reports"

# Sidecar writes every ~30s; samples older than this are not "live".
FRESH_SECONDS = 120
# Known pin (prod cutover 2026-08-08). Prefer a future sidecar version gauge.
DEPLOY_PIN_VERSION = "3.3.0"
# How far back to look for the latest raw gauge (sidecar cadence ~30s).
LATEST_LOOKBACK = timedelta(minutes=10)
HISTORY_DAYS = 7
HISTORY_ALIGN_S = 3600
# Cap self-accumulated agreement snapshot series.
AGREE_SNAP_MAX = 500

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
    """ADC first (Cloud Run / GCE), then gcloud CLI (local laptop)."""
    try:
        import google.auth  # type: ignore
        import google.auth.transport.requests  # type: ignore

        creds, _ = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        creds.refresh(google.auth.transport.requests.Request())
        if creds.token:
            return creds.token
    except Exception:
        pass
    try:
        out = subprocess.check_output(
            ["gcloud", "auth", "print-access-token"], text=True
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        raise SystemExit(
            "no credentials: ADC failed and gcloud auth print-access-token failed "
            f"({e})"
        ) from e
    if not out:
        raise SystemExit("empty access token — run gcloud auth login or use ADC")
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
    start: datetime,
    end: datetime,
    *,
    metric: str | None = None,
    filter_expr: str | None = None,
    align_seconds: int | None = None,
    aligner: str = "ALIGN_MEAN",
    page_size: int = 250,
    timeout: float = 20.0,
) -> list:
    """Fetch time series. Prefer one starts_with filter over N per-metric calls."""
    if filter_expr:
        filt = filter_expr
    elif metric:
        filt = f'metric.type="{METRIC_PREFIX}/{metric}"'
    else:
        raise ValueError("metric or filter_expr required")
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
        for attempt in range(6):
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
                if e.code in (429, 500, 503) and attempt < 5:
                    time.sleep((1.2 * (2**attempt)) + 0.25)
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


def _metric_short_name(series_item: dict) -> str | None:
    mtype = (series_item.get("metric") or {}).get("type") or ""
    if mtype.startswith(METRIC_PREFIX + "/"):
        return mtype[len(METRIC_PREFIX) + 1 :]
    return None


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


def _window_score(win: dict | None) -> dict | None:
    """Normalize {missed,total,score,incomplete} → pct fields. None if absent."""
    if not win or not isinstance(win, dict):
        return None
    raw = win.get("score")
    try:
        score = float(raw) if raw is not None else None
    except (TypeError, ValueError):
        score = None
    if score is None:
        return None
    # Clamp observer noise; score is a ratio in [0,1].
    score = max(0.0, min(1.0, score))
    missed = win.get("missed")
    total = win.get("total")
    try:
        missed_i = int(missed) if missed is not None else None
    except (TypeError, ValueError):
        missed_i = None
    try:
        total_i = int(total) if total is not None else None
    except (TypeError, ValueError):
        total_i = None
    return {
        "score": round(score, 5),
        "pct": round(score * 100.0, 3),
        "missed": missed_i,
        "total": total_i,
        "incomplete": bool(win.get("incomplete")),
    }


def fetch_agreement_xrpl_org() -> tuple[dict | None, list[dict], float]:
    """Return (agreement_block, daily_report_points_pct, elapsed_s).

    Source: data.xrpl.org Validator History Service (XRPL.org explorer backend).
    Lookup by domain first (signing key can rotate; master may be null on-chain).
    """
    t0 = time.perf_counter()
    rec: dict | None = None
    try:
        with urllib.request.urlopen(XRPL_ORG_VALIDATORS, timeout=12) as resp:
            data = json.load(resp)
        for v in data.get("validators") or []:
            if v.get("domain") == DOMAIN:
                rec = v
                break
            mk = v.get("master_key") or ""
            if mk == PUBLIC_VALIDATOR_MASTER_KEY:
                rec = v
                break
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError):
        rec = None

    # Fallback: try known master on single endpoint (may 5xx — ignore).
    if rec is None:
        try:
            url = XRPL_ORG_VALIDATOR + urllib.parse.quote(
                PUBLIC_VALIDATOR_MASTER_KEY, safe=""
            )
            with urllib.request.urlopen(url, timeout=10) as resp:
                rec = json.load(resp)
            if rec.get("result") == "error":
                rec = None
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError):
            rec = None

    if not rec:
        return None, [], time.perf_counter() - t0

    signing = rec.get("signing_key") or rec.get("validation_public_key")
    agreement = {
        "source": "data.xrpl.org",
        "source_detail": (
            "XRPL.org Validator History Service — network-wide observer of "
            "validation messages. Not XRPScan. Not our sidecar (agreement is "
            "not measurable from localhost admin RPC alone)."
        ),
        "signing_key": signing,
        "master_key": rec.get("master_key"),
        "domain": rec.get("domain"),
        "server_version_observed": rec.get("server_version"),
        "unl": rec.get("unl"),
        "agreement_1h": _window_score(rec.get("agreement_1h") or rec.get("agreement_1hour")),
        "agreement_24h": _window_score(
            rec.get("agreement_24h") or rec.get("agreement_24hour")
        ),
        "agreement_30d": _window_score(
            rec.get("agreement_30day") or rec.get("agreement_30d")
        ),
    }

    daily: list[dict] = []
    if signing:
        try:
            url = (
                XRPL_ORG_VALIDATOR
                + urllib.parse.quote(signing, safe="")
                + XRPL_ORG_REPORTS_SUFFIX
            )
            with urllib.request.urlopen(url, timeout=12) as resp:
                rep = json.load(resp)
            for r in rep.get("reports") or []:
                if r.get("chain") and r.get("chain") not in ("main", "mainnet"):
                    continue
                sc = _window_score(
                    {"score": r.get("score"), "missed": r.get("missed"), "total": r.get("total"),
                     "incomplete": r.get("incomplete")}
                )
                if not sc:
                    continue
                daily.append({"t": r.get("date"), "v": sc["pct"], "incomplete": sc["incomplete"]})
            daily.sort(key=lambda p: p.get("t") or "")
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError):
            daily = []

    return agreement, daily, time.perf_counter() - t0


def load_prior_agreement_snaps(token: str | None = None) -> list[dict]:
    """Read previously published agreement_1h snapshots from GCS (best-effort)."""
    try:
        if token:
            url = (
                f"https://storage.googleapis.com/storage/v1/b/{BUCKET}/o/"
                f"{urllib.parse.quote('history.json', safe='')}?alt=media"
            )
            req = urllib.request.Request(
                url, headers={"Authorization": f"Bearer {token}"}
            )
            with urllib.request.urlopen(req, timeout=20) as resp:
                prior = json.load(resp)
        else:
            out = subprocess.check_output(
                ["gcloud", "storage", "cat", f"gs://{BUCKET}/history.json"],
                text=True,
                timeout=20,
                stderr=subprocess.DEVNULL,
            )
            prior = json.loads(out)
        series = (prior.get("series") or {}).get("agreement_1h_snapshots") or []
        return [
            p
            for p in series
            if isinstance(p, dict) and p.get("t") and p.get("v") is not None
        ]
    except (
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
        json.JSONDecodeError,
        FileNotFoundError,
        urllib.error.HTTPError,
        urllib.error.URLError,
        TimeoutError,
    ):
        return []


def merge_agreement_snaps(
    prior: list[dict], *, now: datetime, pct: float | None
) -> list[dict]:
    """Append current 1h agreement pct; drop points older than HISTORY_DAYS."""
    cutoff = (now - timedelta(days=HISTORY_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = [p for p in prior if (p.get("t") or "") >= cutoff]
    if pct is not None:
        ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")
        # Dedupe same-minute republish
        if not out or out[-1].get("t") != ts:
            out.append({"t": ts, "v": round(pct, 3)})
        else:
            out[-1] = {"t": ts, "v": round(pct, 3)}
    if len(out) > AGREE_SNAP_MAX:
        out = out[-AGREE_SNAP_MAX:]
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

    def fetch_hist(name: str, aligner: str):
        t = time.perf_counter()
        series = monitoring_get(
            token,
            start_hist,
            now,
            metric=name,
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
    agreement: dict | None = None
    daily_agree: list[dict] = []
    prior_snaps: list[dict] = []

    # Monitoring: one metric type per request (API constraint). Fan-out causes
    # hard 429s — run latest gauges sequentially, history+agreement in parallel.
    t_lat = time.perf_counter()
    for i, name in enumerate(LATEST_METRICS):
        if i:
            time.sleep(0.12)  # soft pacing under project quota
        try:
            series = monitoring_get(
                token,
                start_latest,
                now,
                metric=name,
                page_size=1,
                timeout=20.0,
            )
            val, sample_ts = latest_sample(series)
            metrics[name] = val
            sample_times[name] = sample_ts
            timings[f"latest.{name}"] = round(time.perf_counter() - t_lat, 3)
        except urllib.error.HTTPError as e:
            timings[f"latest.{name}_err"] = e.code
            metrics[name] = None
            sample_times[name] = None
    timings["latest.sequential"] = round(time.perf_counter() - t_lat, 3)

    with ThreadPoolExecutor(max_workers=4) as pool:
        hist_peer = pool.submit(fetch_hist, "peer_count", "ALIGN_MEAN")
        hist_prop = pool.submit(fetch_hist, "proposing", "ALIGN_MEAN")
        agree_fut = pool.submit(fetch_agreement_xrpl_org)
        prior_fut = pool.submit(load_prior_agreement_snaps, token)
        try:
            _, peer_hist, dt_p = hist_peer.result()
            timings["hist.peer_count"] = round(dt_p, 3)
        except urllib.error.HTTPError as e:
            timings["hist.peer_count_err"] = e.code
            peer_hist = []
        try:
            _, prop_hist, dt_pr = hist_prop.result()
            timings["hist.proposing"] = round(dt_pr, 3)
        except urllib.error.HTTPError as e:
            timings["hist.proposing_err"] = e.code
            prop_hist = []
        agreement, daily_agree, dt_ag = agree_fut.result()
        timings["agreement_xrpl_org"] = round(dt_ag, 3)
        prior_snaps = prior_fut.result()

    t_ver = time.perf_counter()
    if with_version_logs:
        ver_log, ver_evidence = version_from_logs()
    else:
        ver_log, ver_evidence = None, None
    timings["version_logs"] = round(time.perf_counter() - t_ver, 3)

    # Prefer deploy pin; cross-check XRPL.org observed version when present.
    observed_ver = (agreement or {}).get("server_version_observed") if agreement else None
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
    if observed_ver and str(observed_ver).startswith(DEPLOY_PIN_VERSION[:3]):
        # e.g. "3.3.0" from network observer — stronger than pin alone when equal.
        if str(observed_ver).startswith(DEPLOY_PIN_VERSION) or DEPLOY_PIN_VERSION in str(
            observed_ver
        ):
            ver = DEPLOY_PIN_VERSION
            ver_source = "deploy_pin+xrpl_org_observed"
            ver_evidence = (
                f"Deploy pin {DEPLOY_PIN_VERSION}; data.xrpl.org reports "
                f"server_version={observed_ver}."
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
        "agreement": agreement,
    }

    a1 = (agreement or {}).get("agreement_1h") if agreement else None
    a1_pct = a1.get("pct") if a1 else None
    agree_snaps = merge_agreement_snaps(prior_snaps, now=now, pct=a1_pct)
    # Prefer official daily reports when present; else accumulated 1h snapshots.
    agree_series = daily_agree if daily_agree else agree_snaps
    agree_series_kind = (
        "data.xrpl.org daily reports (pct)"
        if daily_agree
        else "accumulated agreement_1h snapshots at publish (pct)"
    )

    history = {
        "schema": "csyn-validator-public-history/v2",
        "source": "cloud-monitoring-sidecar+data.xrpl.org",
        "published_at": status["published_at"],
        "alignment": {
            "peer_count": f"{HISTORY_ALIGN_S}s ALIGN_MEAN",
            "proposing": f"{HISTORY_ALIGN_S}s ALIGN_MEAN (≈ fraction of hour proposing)",
            "agreement": agree_series_kind,
        },
        "window_days": HISTORY_DAYS,
        "series": {
            "peer_count": peer_hist,
            "proposing": prop_hist,
            "agreement": agree_series,
            "agreement_1h_snapshots": agree_snaps,
        },
        "point_counts": {
            "peer_count": len(peer_hist),
            "proposing": len(prop_hist),
            "agreement": len(agree_series),
            "agreement_1h_snapshots": len(agree_snaps),
        },
    }

    timings["total_build"] = round(time.perf_counter() - t0, 3)
    return status, history, timings


def upload_gcs(
    local: Path, object_name: str, content_type: str, token: str | None = None
) -> None:
    """Upload via GCS JSON API (ADC/token) or gcloud CLI fallback.

    Media upload does NOT persist Cache-Control from request headers — after a
    token upload we PATCH object metadata so CDN max-age=15 actually lands.
    """
    body = local.read_bytes()
    cache_control = "public, max-age=15, must-revalidate"
    if token:
        url = (
            f"https://storage.googleapis.com/upload/storage/v1/b/{BUCKET}/o"
            f"?uploadType=media&name={urllib.parse.quote(object_name, safe='')}"
        )
        req = urllib.request.Request(
            url,
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": content_type,
            },
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            if resp.status not in (200, 201):
                raise RuntimeError(f"GCS upload {object_name} HTTP {resp.status}")
        # Persist cacheControl (media upload ignores it as a request header).
        meta_url = (
            f"https://storage.googleapis.com/storage/v1/b/{BUCKET}/o/"
            f"{urllib.parse.quote(object_name, safe='')}"
        )
        meta_body = json.dumps({"cacheControl": cache_control}).encode()
        meta_req = urllib.request.Request(
            meta_url,
            data=meta_body,
            method="PATCH",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(meta_req, timeout=30) as resp:
            if resp.status not in (200, 201):
                raise RuntimeError(
                    f"GCS cacheControl PATCH {object_name} HTTP {resp.status}"
                )
        return
    subprocess.check_call(
        [
            "gcloud",
            "storage",
            "cp",
            str(local),
            f"gs://{BUCKET}/{object_name}",
            f"--content-type={content_type}",
            f"--cache-control={cache_control}",
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
    ag = status.get("agreement") or {}
    a1 = (ag.get("agreement_1h") or {}) if ag else {}
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
                "agreement_1h_pct": a1.get("pct"),
                "agreement_24h_pct": (ag.get("agreement_24h") or {}).get("pct"),
                "agreement_30d_pct": (ag.get("agreement_30d") or {}).get("pct"),
                "history_points": history["point_counts"],
                "timings_s": timings,
            },
            indent=2,
        )
    )

    if args.upload:
        t_up = time.perf_counter()
        upload_gcs(status_path, "status.json", "application/json", token=token)
        upload_gcs(history_path, "history.json", "application/json", token=token)
        print(
            f"uploaded gs://{BUCKET}/{{status,history}}.json "
            f"in {time.perf_counter() - t_up:.2f}s"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
