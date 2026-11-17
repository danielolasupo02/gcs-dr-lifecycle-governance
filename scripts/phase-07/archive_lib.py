"""Shared helpers for the phase 07 validation and DR drill scripts."""
import time

from google.api_core import exceptions

TIMEOUT_S = 600
POLL_S = 15

RESULTS = []


def check(desc, ok):
    RESULTS.append(bool(ok))
    print(f"  [{'PASS' if ok else 'FAIL'}] {desc}")
    return ok


def summary(label):
    passed = sum(RESULTS)
    failed = len(RESULTS) - passed
    print(f"\n{label}: {passed} passed, {failed} failed")
    return 0 if failed == 0 and RESULTS else 1


def live_bytes(bucket, name):
    try:
        blob = bucket.get_blob(name)
        return blob, (blob.download_as_bytes() if blob else None)
    except exceptions.NotFound:
        return None, None


def wait_for(bucket, name, expected, label):
    """Poll until the live object has the expected bytes. Returns (seconds, blob) or (None, None)."""
    start = time.monotonic()
    print(f"  waiting for {label} in gs://{bucket.name}/{name}", flush=True)
    while time.monotonic() - start < TIMEOUT_S:
        blob, data = live_bytes(bucket, name)
        if data == expected:
            return round(time.monotonic() - start), blob
        time.sleep(POLL_S)
        print(f"    ... {round(time.monotonic() - start)}s", flush=True)
    return None, None


def versions(client, bucket, name):
    """All generations of one object, oldest first."""
    blobs = [b for b in client.list_blobs(bucket, prefix=name, versions=True) if b.name == name]
    return sorted(blobs, key=lambda b: b.generation)


def key_short(blob):
    key = blob.kms_key_name or "GOOGLE_MANAGED"
    return key.split("/cryptoKeys/")[-1].replace("/cryptoKeyVersions/", " v")


def print_versions(client, bucket, name):
    print(f"\n  gs://{bucket.name}/{name}")
    print(f"    {'GENERATION':<18} {'STATE':<11} {'CLASS':<9} {'KEY':<22} CONTENT")
    for b in versions(client, bucket, name):
        state = "noncurrent" if b.time_deleted else "LIVE"
        first = b.download_as_bytes().decode(errors="replace").splitlines()[0][:40]
        print(f"    {b.generation:<18} {state:<11} {b.storage_class:<9} {key_short(b):<22} {first}")


def rewrite_into(source_blob, dest_bucket, name, kms_key):
    """Server-side rewrite of one generation into dest_bucket/name, encrypted with kms_key.

    Rewrite (not copy) is used because it can change location and encryption key, and it
    resumes with a token for large objects. source_blob.generation selects the version.
    """
    dest = dest_bucket.blob(name, kms_key_name=kms_key)
    token, _, _ = dest.rewrite(source_blob)
    while token is not None:
        token, _, _ = dest.rewrite(source_blob, token=token)
    return dest_bucket.get_blob(name)
