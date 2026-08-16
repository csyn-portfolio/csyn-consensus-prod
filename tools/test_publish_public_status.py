import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from publish_public_status import AGREE_SNAP_MAX, HISTORY_DAYS, merge_agreement_snaps


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


if __name__ == "__main__":
    unittest.main()
