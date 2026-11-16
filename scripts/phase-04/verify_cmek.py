"""Phase 04: verify CMEK keys, IAM, bucket encryption settings, and real object encryption.

For each bucket/key pair it checks the key in Cloud KMS, the service agent's role on it,
the bucket's default key and enforcement config, then writes a small probe object WITHOUT
naming a key and confirms Cloud Storage encrypted it with the CMEK anyway.

Usage:
  python scripts/phase-04/verify_cmek.py <project-id> <service-agent-email> \
      <primary-bucket> <primary-key-id> <secondary-bucket> <secondary-key-id>
Exit 0 when every check passes, 1 otherwise.
"""
import datetime
import sys

from google.api_core import exceptions
from google.cloud import kms, storage

EXPECTED_ROTATION_DAYS = 90
ENCRYPTER_ROLE = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
PROBE_OBJECT = "_probes/cmek-probe.txt"


def seconds(duration):
    """Rotation period comes back as a timedelta or a protobuf Duration depending on library version."""
    if isinstance(duration, datetime.timedelta):
        return int(duration.total_seconds())
    return int(getattr(duration, "seconds", 0))


def key_region(key_id):
    parts = key_id.split("/")
    return parts[parts.index("locations") + 1] if "locations" in parts else ""


def check_pair(gcs, kms_client, agent, bucket_name, key_id, role):
    print(f"\n{role}: gs://{bucket_name}")
    print(f"  key: {key_id}")
    checks = []

    # ---- Cloud KMS key ----
    try:
        key = kms_client.get_crypto_key(name=key_id)
        checks += [
            ("key purpose is ENCRYPT_DECRYPT", key.purpose.name == "ENCRYPT_DECRYPT"),
            (f"rotation period is {EXPECTED_ROTATION_DAYS} days",
             seconds(key.rotation_period) == EXPECTED_ROTATION_DAYS * 86400),
            ("next rotation is scheduled", bool(key.next_rotation_time)),
            ("primary key version is ENABLED", key.primary.state.name == "ENABLED"),
            ("protection level is SOFTWARE", key.version_template.protection_level.name == "SOFTWARE"),
        ]
    except (exceptions.NotFound, exceptions.Forbidden) as err:
        checks.append((f"key readable ({err.__class__.__name__})", False))

    try:
        policy = kms_client.get_iam_policy(request={"resource": key_id})
        members = {m for b in policy.bindings if b.role == ENCRYPTER_ROLE for m in b.members}
        checks.append((f"service agent has {ENCRYPTER_ROLE.split('/')[-1]}", f"serviceAccount:{agent}" in members))
    except exceptions.GoogleAPICallError as err:
        checks.append((f"key IAM policy readable ({err.__class__.__name__})", False))

    # ---- Bucket settings ----
    try:
        bucket = gcs.get_bucket(bucket_name)
        enc = bucket._properties.get("encryption", {})
        gmek = enc.get("googleManagedEncryptionEnforcementConfig", {}).get("restrictionMode")
        csek = enc.get("customerSuppliedEncryptionEnforcementConfig", {}).get("restrictionMode")
        checks += [
            ("key is in the same region as the bucket", key_region(key_id).lower() == (bucket.location or "").lower()),
            ("bucket default key is this CMEK", bucket.default_kms_key_name == key_id),
            ("Google-managed encryption FullyRestricted", gmek == "FullyRestricted"),
            ("customer-supplied keys FullyRestricted", csek == "FullyRestricted"),
        ]

        # ---- Real write: no key named, CMEK expected ----
        blob = bucket.blob(PROBE_OBJECT)
        blob.upload_from_string(
            f"cmek probe {datetime.datetime.now(datetime.timezone.utc).isoformat()}\n",
            content_type="text/plain",
        )
        blob.reload()
        used = blob.kms_key_name or ""
        print(f"  probe object encrypted with: {used.split('/cryptoKeys/')[-1] or 'Google-managed'}")
        checks.append(("probe written without a key is CMEK-encrypted", used.startswith(key_id + "/cryptoKeyVersions/")))
    except exceptions.GoogleAPICallError as err:
        checks.append((f"bucket checks and probe write ({err.__class__.__name__}: {err.message[:80]})", False))

    passed = failed = 0
    for desc, ok in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] {desc}")
        passed += ok
        failed += not ok
    return passed, failed


def main(argv):
    if len(argv) != 7:
        print(__doc__)
        return 2
    project, agent, p_bucket, p_key, s_bucket, s_key = argv[1:]
    gcs = storage.Client(project=project)
    kms_client = kms.KeyManagementServiceClient()

    p_pass, p_fail = check_pair(gcs, kms_client, agent, p_bucket, p_key, "primary")
    s_pass, s_fail = check_pair(gcs, kms_client, agent, s_bucket, s_key, "secondary")

    print(f"\nCMEK: {p_pass + s_pass} passed, {p_fail + s_fail} failed")
    return 0 if p_fail + s_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
