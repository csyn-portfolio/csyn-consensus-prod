import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from publish_public_status import (
    AGREE_SNAP_MAX,
    HISTORY_DAYS,
    HOUR_LEDGER_CEILING,
    PUBLIC_VALIDATOR_MASTER_KEY,
    _window_score,
    daily_agreement_points,
    merge_agreement_snaps,
    observer_windows,
    select_observer_window,
    vhs_reports_key,
)


class TestHistoryWindow(unittest.TestCase):
    def test_history_days_is_thirty(self):
        self.assertEqual(HISTORY_DAYS, 30)

    def test_snap_cap_covers_thirty_days_at_five_min(self):
        # 30d * 24h * 12 publishes/hour = 8640
        self.assertGreaterEqual(AGREE_SNAP_MAX, 8640)

    def test_merge_drops_points_older_than_window(self):
        now = datetime(2026, 8, 16, 12, 0, tzinfo=timezone.utc)
        old = {
            "t": (now - timedelta(days=31)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "v": 99.0,
        }
        keep = {
            "t": (now - timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "v": 99.5,
        }
        out = merge_agreement_snaps([old, keep], now=now, pct=100.0)
        cutoff = (now - timedelta(days=HISTORY_DAYS)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        self.assertTrue(all((p["t"] or "") >= cutoff for p in out))
        self.assertEqual(out[-1]["v"], 100.0)


SIGNING = "n9Lx3VU74ghkm29Gg5ay3xzynDhpUqaH8BLMFYc3MBrWT8pxKWk4"


class VhsReportsKeyTests(unittest.TestCase):
    """VHS /reports is keyed by master identity. Signing-key reports return count=0."""

    def test_prefers_master_when_both_present(self):
        rec = {"master_key": PUBLIC_VALIDATOR_MASTER_KEY, "signing_key": SIGNING}
        self.assertEqual(vhs_reports_key(rec), PUBLIC_VALIDATOR_MASTER_KEY)

    def test_uses_known_master_when_list_omits_master(self):
        rec = {
            "master_key": None,
            "signing_key": SIGNING,
            "validation_public_key": SIGNING,
        }
        self.assertEqual(vhs_reports_key(rec), PUBLIC_VALIDATOR_MASTER_KEY)

    def test_never_returns_signing_key(self):
        rec = {"signing_key": SIGNING, "validation_public_key": SIGNING}
        key = vhs_reports_key(rec)
        self.assertNotEqual(key, SIGNING)
        self.assertEqual(key, PUBLIC_VALIDATOR_MASTER_KEY)


def _win(score, missed, total, incomplete=False):
    return {
        "score": score,
        "missed": missed,
        "total": total,
        "incomplete": incomplete,
    }


class ObserverWindowTests(unittest.TestCase):
    """A returned window is the observer's own score. Withhold only when the
    ledger count is not a measurement for that horizon."""

    def test_ceiling_is_one_hour_of_ledgers(self):
        self.assertEqual(HOUR_LEDGER_CEILING, 2000)

    def test_real_1h_passes_through_unchanged(self):
        raw = _win(0.99818, 2, 1100, incomplete=False)
        got = select_observer_window(raw, "1h")
        self.assertEqual(got, _window_score(raw))

    def test_low_percent_with_a_real_hour_is_kept(self):
        # 50% of 1000 ledgers is a low score, and it is still one hour.
        raw = _win(0.5, 1, 1000)
        got = select_observer_window(raw, "1h")
        self.assertEqual(got["pct"], 50.0)
        self.assertEqual(got["score"], 0.5)
        self.assertEqual(got["missed"], 1)
        self.assertEqual(got["total"], 1000)

    def test_1h_at_ceiling_is_kept_and_one_past_is_withheld(self):
        kept = select_observer_window(_win(1, 0, HOUR_LEDGER_CEILING), "1h")
        self.assertEqual(kept["pct"], 100.0)
        self.assertEqual(kept["total"], HOUR_LEDGER_CEILING)
        held = select_observer_window(_win(1, 0, HOUR_LEDGER_CEILING + 1), "1h")
        self.assertNotIn("pct", held)
        self.assertNotIn("score", held)
        self.assertEqual(held["total"], HOUR_LEDGER_CEILING + 1)

    def test_empty_or_giant_1h_has_counts_and_no_percentage(self):
        empty = select_observer_window(_win(0, 0, 0, incomplete=False), "1h")
        self.assertEqual(empty, {"missed": 0, "total": 0, "incomplete": False})
        giant = select_observer_window(
            _win(0.07698, 22495, 24371, incomplete=True), "1h"
        )
        self.assertEqual(
            giant, {"missed": 22495, "total": 24371, "incomplete": True}
        )

    def test_missing_total_with_a_score_still_publishes_that_score(self):
        raw = {"score": 0.974, "missed": 26, "incomplete": False}
        got = select_observer_window(raw, "1h")
        self.assertEqual(got["pct"], 97.4)
        self.assertIsNone(got["total"])

    def test_real_24h_and_30d_pass_through_above_the_hour_ceiling(self):
        hour = _win(0.07698, 22495, 24371, incomplete=True)
        day = _win(0.991, 200, 24000)
        month = _win(0.96022, 22977, 577634, incomplete=True)
        self.assertEqual(select_observer_window(day, "24h", hour), _window_score(day))
        got = select_observer_window(month, "30d", hour)
        self.assertEqual(got, _window_score(month))
        self.assertEqual(got["pct"], 96.022)
        self.assertEqual(got["missed"], 22977)
        self.assertEqual(got["total"], 577634)

    def test_24h_and_30d_that_copy_a_failed_1h_are_withheld(self):
        hour = _win(0.08, 20000, 22000, incomplete=True)
        self.assertNotIn("pct", select_observer_window(dict(hour), "24h", hour))
        self.assertNotIn("pct", select_observer_window(dict(hour), "30d", hour))

    def test_same_counts_as_a_healthy_1h_are_kept(self):
        hour = _win(0.99, 11, 1100)
        day = _win(0.99, 11, 1100)
        self.assertEqual(select_observer_window(day, "24h", hour), _window_score(day))

    def test_same_total_with_a_different_miss_count_is_kept(self):
        hour = _win(0.07, 22000, 24371, incomplete=True)
        day = _win(0.5, 10000, 24371)
        got = select_observer_window(day, "24h", hour)
        self.assertEqual(got["pct"], 50.0)
        self.assertEqual(got["missed"], 10000)

    def test_genuine_low_month_beside_a_healthy_hour_is_kept(self):
        hour = _win(0.999, 1, 1000)
        month = _win(0.96, 20000, 500000)
        got = select_observer_window(month, "30d", hour)
        self.assertEqual(got["pct"], 96.0)
        self.assertEqual(got["total"], 500000)

    def test_record_windows_match_the_live_shape(self):
        out = observer_windows(
            {
                "agreement_1h": _win(0.07698, 22495, 24371, incomplete=True),
                "agreement_24hour": _win(0, 0, 0),
                "agreement_30day": _win(0.96022, 22977, 577634, incomplete=True),
            }
        )
        self.assertNotIn("pct", out["agreement_1h"])
        self.assertNotIn("pct", out["agreement_24h"])
        self.assertEqual(out["agreement_30d"]["pct"], 96.022)
        self.assertEqual(out["agreement_30d"]["incomplete"], True)

    def test_daily_keeps_a_partial_day_and_skips_an_empty_one(self):
        points = daily_agreement_points(
            [
                {"date": "2026-10-03", "score": 0, "missed": 0, "total": 0, "chain": "main"},
                {
                    "date": "2026-10-02",
                    "score": 0.998,
                    "missed": 2,
                    "total": 900,
                    "incomplete": True,
                    "chain": "mainnet",
                },
                {
                    "date": "2026-10-01",
                    "score": 1,
                    "missed": 0,
                    "total": 3700,
                    "incomplete": False,
                    "chain": "main",
                },
                {
                    "date": "2026-09-30",
                    "score": 1,
                    "missed": 0,
                    "total": 1000,
                    "chain": "testnet",
                },
            ]
        )
        self.assertEqual(
            points,
            [
                {"t": "2026-10-01", "v": 100.0, "incomplete": False},
                {"t": "2026-10-02", "v": 99.8, "incomplete": True},
            ],
        )

    def test_withheld_1h_does_not_append_a_snapshot(self):
        now = datetime(2026, 10, 3, 19, 0, tzinfo=timezone.utc)
        prior = [{"t": "2026-10-02T20:05:00Z", "v": 66.165}]
        withheld = select_observer_window(_win(0.07698, 22495, 24371, True), "1h")
        self.assertIsNone(withheld.get("pct") if withheld else None)
        out = merge_agreement_snaps(prior, now=now, pct=withheld.get("pct") if withheld else None)
        self.assertEqual(out, prior)


if __name__ == "__main__":
    unittest.main()
