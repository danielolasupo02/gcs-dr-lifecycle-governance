"""Phase 05: live checks for cross-bucket replication.

Subcommands:
  verify     Bucket IAM for the transfer agent, then upload a fresh probe to primary and
             wait for it to appear in secondary, encrypted with the secondary key.
  delete     DR scenario: delete an object in primary and confirm the secondary copy survives.
  overwrite  DR scenario: overwrite an object with bad data and confirm the good version is
             still recoverable from secondary's version history.

Usage:
  python replication_check.py verify    <project> <primary> <secondary> <sts-agent> <secondary-key-id>
  python replication_check.py delete    <project> <primary> <secondary>
  python replication_check.py overwrite <project> <primary> <secondary>

All test objects go under _probes/. Exit 0 when every check passes, 1 otherwise.
"""
import datetime
import sys
import time
import uuid

from google.api_core import exceptions
from google.cloud import storage

TIMEOUT_S = 600
POLL_S = 15
DELETE_GRACE_S = 120

RESULTS = []


def check(desc, ok):
    RESULTS.append(ok)
    print(f"  [{'PASS' if ok else 'FAIL'}] {desc}")
    return ok


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def read_live(bucket, name):
    blob = bucket.get_blob(name)
    return (blob, blob.download_as_bytes()) if blob else (None, None)


def wait_for_content(bucket, name, expected, label):
    """Poll until bucket/name exists with the expected bytes. Returns seconds taken, or None."""
    start = time.monotonic()
    print(f"  waiting for {label} in gs://{bucket.name}/{name} (timeout {TIMEOUT_S}s)", flush=True)
    while time.monotonic() - start < TIMEOUT_S:
        try:
            blob, data = read_live(bucket, name)
            if data == expected:
                return round(time.monotonic() - start), blob
        except exceptions.NotFound:
            pass
        time.sleep(POLL_S)
        print(f"    ... {round(time.monotonic() - start)}s", flush=True)
    return None, None


def iam_members(bucket, role):
    policy = bucket.get_iam_policy(requested_policy_version=3)
    return {m for b in policy.bindings if b["role"] == role for m in b["members"]}


def cmd_verify(client, primary, secondary, agent, secondary_key):
    member = f"serviceAccount:{agent}"
    print("\nTransfer agent bucket IAM")
    check("source: legacyBucketOwner", member in iam_members(primary, "roles/storage.legacyBucketOwner"))
    check("source: objectViewer", member in iam_members(primary, "roles/storage.objectViewer"))
    check("sink: objectUser", member in iam_members(secondary, "roles/storage.objectUser"))
    check("sink: legacyBucketReader", member in iam_members(secondary, "roles/storage.legacyBucketReader"))
    check("sink: agent has no admin role on the DR copy", member not in iam_members(secondary, "roles/storage.admin"))

    print("\nLive replication")
    name = f"_probes/replication-{stamp()}.txt"
    payload = f"replication probe {uuid.uuid4()}\n".encode()
    primary.blob(name).upload_from_string(payload, content_type="text/plain")
    print(f"  uploaded gs://{primary.name}/{name}")

    seconds, replica = wait_for_content(secondary, name, payload, "replica")
    if not check(f"object replicated to secondary ({seconds}s)" if seconds is not None else "object replicated to secondary", seconds is not None):
        return
    check("replica content matches byte for byte", replica.download_as_bytes() == payload)
    check("replica encrypted with the secondary region key",
          (replica.kms_key_name or "").startswith(secondary_key + "/cryptoKeyVersions/"))
    check("replica lands in STANDARD (secondary lifecycle tiers it later)", replica.storage_class == "STANDARD")


def make_replicated(primary, secondary, prefix):
    name = f"_probes/{prefix}-{stamp()}.txt"
    good = f"good copy {uuid.uuid4()}\n".encode()
    primary.blob(name).upload_from_string(good, content_type="text/plain")
    print(f"  uploaded gs://{primary.name}/{name}")
    seconds, _ = wait_for_content(secondary, name, good, "replica")
    check(f"setup: object replicated ({seconds}s)" if seconds is not None else "setup: object replicated", seconds is not None)
    return name, good, seconds is not None


def cmd_delete(client, primary, secondary):
    print("\nT1: deleting an object in primary does not delete the DR copy")
    name, good, ok = make_replicated(primary, secondary, "delete-test")
    if not ok:
        return
    primary.blob(name).delete()
    print(f"  deleted live object in primary; waiting {DELETE_GRACE_S}s for any propagation", flush=True)
    time.sleep(DELETE_GRACE_S)
    check("primary has no live copy", primary.get_blob(name) is None)
    _, data = read_live(secondary, name)
    check("secondary still serves the original content", data == good)


def cmd_overwrite(client, primary, secondary):
    print("\nT2: a bad overwrite replicates, but the good version stays recoverable in secondary")
    name, good, ok = make_replicated(primary, secondary, "overwrite-test")
    if not ok:
        return
    bad = f"CORRUPTED {uuid.uuid4()}\n".encode()
    primary.blob(name).upload_from_string(bad, content_type="text/plain")
    print("  overwrote primary with corrupted content")
    seconds, _ = wait_for_content(secondary, name, bad, "corrupted overwrite")
    check(f"overwrite replicated to secondary ({seconds}s)" if seconds is not None else "overwrite replicated to secondary", seconds is not None)

    versions = list(client.list_blobs(secondary, prefix=name, versions=True))
    good_versions = [v for v in versions if v.download_as_bytes() == good]
    check(f"secondary keeps {len(versions)} versions of the object", len(versions) >= 2)
    if check("good version is still in secondary's history", bool(good_versions)):
        gen = good_versions[0].generation
        print(f"  restore with: gcloud storage cp gs://{secondary.name}/{name}#{gen} gs://{primary.name}/{name}")


def main(argv):
    if len(argv) < 5 or argv[1] not in ("verify", "delete", "overwrite"):
        print(__doc__)
        return 2
    cmd, project, p_name, s_name = argv[1:5]
    client = storage.Client(project=project)
    primary, secondary = client.bucket(p_name), client.bucket(s_name)

    try:
        if cmd == "verify":
            if len(argv) != 7:
                print(__doc__)
                return 2
            cmd_verify(client, primary, secondary, argv[5], argv[6])
        elif cmd == "delete":
            cmd_delete(client, primary, secondary)
        else:
            cmd_overwrite(client, primary, secondary)
    except exceptions.GoogleAPICallError as err:
        check(f"API call failed: {err.__class__.__name__}: {err.message[:100]}", False)

    passed, failed = sum(RESULTS), len(RESULTS) - sum(RESULTS)
    print(f"\nReplication ({cmd}): {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
