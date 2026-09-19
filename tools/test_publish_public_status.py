"""Tests for publish_public_status.py helpers.

vhs_reports_key: VHS /reports is keyed by master identity. Signing-key
reports return count=0 (validator-history-service#503). A plant that used
the signing key would empty the daily series.
"""

from __future__ import annotations

import unittest

import publish_public_status as pub

MASTER = pub.PUBLIC_VALIDATOR_MASTER_KEY
SIGNING = "n9Lx3VU74ghkm29Gg5ay3xzynDhpUqaH8BLMFYc3MBrWT8pxKWk4"


class VhsReportsKeyTests(unittest.TestCase):
    def test_prefers_master_when_both_present(self):
        rec = {"master_key": MASTER, "signing_key": SIGNING}
        self.assertEqual(pub.vhs_reports_key(rec), MASTER)

    def test_uses_known_master_when_list_omits_master(self):
        rec = {
            "master_key": None,
            "signing_key": SIGNING,
            "validation_public_key": SIGNING,
        }
        self.assertEqual(pub.vhs_reports_key(rec), MASTER)

    def test_never_returns_signing_key(self):
        rec = {"signing_key": SIGNING, "validation_public_key": SIGNING}
        key = pub.vhs_reports_key(rec)
        self.assertNotEqual(key, SIGNING)
        self.assertEqual(key, MASTER)


if __name__ == "__main__":
    unittest.main()
