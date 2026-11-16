"""Phase 02: verify the primary and secondary buckets match the intended configuration.

Usage:
  python scripts/phase-02/verify_buckets.py <project-id> <primary-bucket> <primary-region> \
      <secondary-bucket> <secondary-region>
Exit 0 when every check passes, 1 otherwise.
"""
import sys

from google.api_core import exceptions
from google.cloud import storage


def has_rule(bucket, action_type, condition_key):
    for rule in bucket.lifecycle_rules:
        if rule.get("action", {}).get("type") == action_type and condition_key in rule.get("condition", {}):
            return True
    return False


def check_bucket(client, name, region, role):
    print(f"\n{role} bucket: gs://{name}")
    try:
        b = client.get_bucket(name)
    except exceptions.NotFound:
        print("  [FAIL] bucket does not exist")
        return 0, 1
    except exceptions.Forbidden as err:
        print(f"  [FAIL] 403 reading bucket: {err.message}")
        return 0, 1

    iam = b.iam_configuration
    checks = [
        (f"location is {region}", (b.location or "").lower() == region.lower()),
        ("location type is region", b.location_type == "region"),
        ("default storage class is STANDARD", b.storage_class == "STANDARD"),
        ("object versioning enabled", b.versioning_enabled is True),
        ("uniform bucket-level access enabled", iam.uniform_bucket_level_access_enabled is True),
        ("public access prevention enforced", iam.public_access_prevention == "enforced"),
        ("label managed_by=terraform", b.labels.get("managed_by") == "terraform"),
        (f"label role={role}", b.labels.get("role") == role),
        ("lifecycle: delete noncurrent versions", has_rule(b, "Delete", "daysSinceNoncurrentTime")),
        ("lifecycle: abort incomplete multipart uploads", has_rule(b, "AbortIncompleteMultipartUpload", "age")),
    ]

    passed = failed = 0
    for desc, ok in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] {desc}")
        passed += ok
        failed += not ok
    return passed, failed


def main(argv):
    if len(argv) != 6:
        print(__doc__)
        return 2
    project, p_name, p_region, s_name, s_region = argv[1:]
    client = storage.Client(project=project)

    p_pass, p_fail = check_bucket(client, p_name, p_region, "primary")
    s_pass, s_fail = check_bucket(client, s_name, s_region, "secondary")

    cross_ok = p_region.lower() != s_region.lower()
    print(f"\nCross-region\n  [{'PASS' if cross_ok else 'FAIL'}] primary and secondary are in different regions")

    passed = p_pass + s_pass + cross_ok
    failed = p_fail + s_fail + (not cross_ok)
    print(f"\nBuckets: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
