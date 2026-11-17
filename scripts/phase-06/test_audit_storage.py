"""Phase 06: unit tests for the audit policy. No cloud access.

The live buckets cannot contain a non-CMEK object (Phase 4 enforcement refuses it) or a
90-day-old Standard object (they are days old), so the failure paths of the audit are
proven here with synthetic object records.

Run: python -m unittest scripts/phase-06/test_audit_storage.py -v
"""
import datetime as dt
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import audit_storage as a  # noqa: E402

KEY = "projects/p/locations/us-central1/keyRings/fintech-archive-ring/cryptoKeys/archive-primary"
OTHER = "projects/p/locations/us-central1/keyRings/other-ring/cryptoKeys/rogue"
NOW = dt.datetime(2026, 11, 17, 12, 0, tzinfo=dt.timezone.utc)


def obj(age_days, storage_class="STANDARD", key=KEY + "/cryptoKeyVersions/1", crc="AAAAAA==", content=None):
    return {
        "name": "statements/x.txt",
        "storage_class": storage_class,
        "kms_key_name": key,
        "created": NOW - dt.timedelta(days=age_days),
        "crc32c": crc,
        "content_crc32c": content,
    }


def run(o, key_state="ENABLED"):
    findings = a.evaluate(o, KEY, 30, 90, 1.0, NOW, key_state)
    return a.overall(findings), {f[1] for f in findings}


class AuditPolicyTest(unittest.TestCase):
    def test_compliant_new_object_passes(self):
        self.assertEqual(run(obj(2))[0], "PASS")

    def test_google_managed_encryption_fails(self):
        status, codes = run(obj(2, key=None), key_state=None)
        self.assertEqual(status, "FAIL")
        self.assertIn("ENC_NOT_CMEK", codes)

    def test_wrong_key_fails(self):
        status, codes = run(obj(2, key=OTHER + "/cryptoKeyVersions/1"))
        self.assertEqual(status, "FAIL")
        self.assertIn("ENC_WRONG_KEY", codes)

    def test_disabled_key_version_fails(self):
        status, codes = run(obj(2), key_state="DISABLED")
        self.assertEqual(status, "FAIL")
        self.assertIn("KEY_VERSION_DISABLED", codes)

    def test_standard_object_overdue_for_nearline_fails(self):
        status, codes = run(obj(45, "STANDARD"))
        self.assertEqual(status, "FAIL")
        self.assertIn("LIFECYCLE_OVERDUE", codes)

    def test_nearline_object_overdue_for_coldline_fails(self):
        status, codes = run(obj(120, "NEARLINE"))
        self.assertEqual(status, "FAIL")
        self.assertIn("LIFECYCLE_OVERDUE", codes)

    def test_transition_within_grace_is_pending(self):
        status, codes = run(obj(30.5, "STANDARD"))
        self.assertEqual(status, "PENDING")
        self.assertIn("LIFECYCLE_PENDING", codes)

    def test_correctly_tiered_old_object_passes(self):
        self.assertEqual(run(obj(200, "COLDLINE"))[0], "PASS")

    def test_missing_checksum_fails(self):
        status, codes = run(obj(2, crc=None))
        self.assertEqual(status, "FAIL")
        self.assertIn("NO_CHECKSUM", codes)

    def test_content_checksum_mismatch_fails(self):
        status, codes = run(obj(2, crc="AAAAAA==", content="BBBBBB=="))
        self.assertEqual(status, "FAIL")
        self.assertIn("CHECKSUM_MISMATCH", codes)

    def test_expected_class_boundaries(self):
        self.assertEqual(a.expected_class(29.9, 30, 90), "STANDARD")
        self.assertEqual(a.expected_class(30, 30, 90), "NEARLINE")
        self.assertEqual(a.expected_class(89.9, 30, 90), "NEARLINE")
        self.assertEqual(a.expected_class(90, 30, 90), "COLDLINE")


if __name__ == "__main__":
    unittest.main(verbosity=2)
