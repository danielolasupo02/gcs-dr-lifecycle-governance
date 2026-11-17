#!/usr/bin/env python3
"""Automated integrity audit for the fintech archive buckets.

For every live object in each bucket it checks:
  - encryption:  CMEK, with the bucket's expected key, on a key version that is ENABLED
  - lifecycle:   storage class matches the age-based policy (Standard < 30d, Nearline < 90d, then Coldline)
  - integrity:   a CRC32C checksum is recorded, and optionally that the content still matches it
  - DR coverage: the object has a replica in the secondary bucket (primary only)

Writes a JSON compliance report and prints a summary. Exit codes:
  0  no FAIL findings      1  at least one FAIL      2  the audit could not run

Usage (normally via run_audit.sh):
  python audit_storage.py --project P \\
      --bucket PRIMARY=KEY_ID --bucket SECONDARY=KEY_ID \\
      [--replica PRIMARY=SECONDARY] [--replication-since ISO8601] \\
      [--impersonate SA_EMAIL] [--verify-content] [--report reports/audit.json]
"""
import argparse
import base64
import datetime as dt
import json
import os
import sys
from collections import Counter

import google.auth
import google.auth.exceptions
from google.api_core import exceptions
from google.auth import impersonated_credentials
from google.cloud import kms, storage

try:
    import google_crc32c
except ImportError:  # shipped with google-cloud-storage, but stay defensive
    google_crc32c = None

SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]
COLDNESS = {"STANDARD": 0, "NEARLINE": 1, "COLDLINE": 2, "ARCHIVE": 3}
SEVERITY = {"PASS": 0, "PENDING": 1, "WARN": 2, "FAIL": 3}
REPLICATION_GRACE = dt.timedelta(minutes=15)


# ---------------------------------------------------------------- policy (pure, unit tested)

def expected_class(age_days, nearline_days, coldline_days):
    if age_days >= coldline_days:
        return "COLDLINE"
    if age_days >= nearline_days:
        return "NEARLINE"
    return "STANDARD"


def evaluate(obj, expected_key, nearline_days, coldline_days, grace_days, now, key_state=None):
    """Return a list of (status, code, detail) findings for one object record.

    obj keys: name, storage_class, kms_key_name, created (aware datetime), crc32c,
              content_crc32c (None unless content was verified)
    key_state: state of the key version used, e.g. "ENABLED"; None if it could not be read.
    """
    findings = []
    age_days = (now - obj["created"]).total_seconds() / 86400

    # Encryption
    key = obj.get("kms_key_name") or ""
    if not key:
        findings.append(("FAIL", "ENC_NOT_CMEK", "object is not encrypted with a customer-managed key"))
    elif not key.startswith(expected_key + "/cryptoKeyVersions/"):
        findings.append(("FAIL", "ENC_WRONG_KEY", f"encrypted with {key.split('/cryptoKeys/')[-1]}"))
    if key:
        if key_state is None:
            findings.append(("WARN", "KEY_STATE_UNKNOWN", "could not read key version state"))
        elif key_state != "ENABLED":
            findings.append(("FAIL", f"KEY_VERSION_{key_state}", "object cannot be decrypted while its key version is not ENABLED"))

    # Lifecycle
    actual = obj.get("storage_class") or "STANDARD"
    expected = expected_class(age_days, nearline_days, coldline_days)
    if COLDNESS.get(actual, 0) < COLDNESS[expected]:
        boundary = coldline_days if expected == "COLDLINE" else nearline_days
        overdue = age_days - boundary
        if overdue <= grace_days:
            findings.append(("PENDING", "LIFECYCLE_PENDING", f"{actual}, due {expected} {overdue:.1f}d ago (within {grace_days}d grace)"))
        else:
            findings.append(("FAIL", "LIFECYCLE_OVERDUE", f"{actual} at {age_days:.0f}d, policy says {expected}"))
    elif COLDNESS.get(actual, 0) > COLDNESS[expected]:
        findings.append(("WARN", "CLASS_COLDER_THAN_POLICY", f"{actual} at {age_days:.0f}d, policy says {expected}"))

    # Integrity
    if not obj.get("crc32c"):
        findings.append(("FAIL", "NO_CHECKSUM", "no CRC32C recorded"))
    elif obj.get("content_crc32c") is not None and obj["content_crc32c"] != obj["crc32c"]:
        findings.append(("FAIL", "CHECKSUM_MISMATCH", "content does not match recorded CRC32C"))

    return findings


def overall(findings):
    return max((f[0] for f in findings), key=SEVERITY.get, default="PASS")


# ---------------------------------------------------------------- cloud access

def build_credentials(impersonate):
    source, _ = google.auth.default(scopes=SCOPES)
    if not impersonate:
        return source, getattr(source, "service_account_email", None) or "user (Application Default Credentials)"
    creds = impersonated_credentials.Credentials(
        source_credentials=source, target_principal=impersonate, target_scopes=SCOPES, lifetime=900
    )
    return creds, impersonate


def crc32c_of(data):
    c = google_crc32c.Checksum()
    c.update(data)
    return base64.b64encode(c.digest()).decode()


def audit_bucket(client, kms_client, bucket_name, expected_key, args, now, key_cache, replica_names, replication_since):
    bucket = client.get_bucket(bucket_name)  # NotFound / Forbidden handled by caller
    records = []
    for blob in client.list_blobs(bucket):
        key = blob.kms_key_name or ""
        version = key  # kms_key_name already includes /cryptoKeyVersions/N
        if key and version not in key_cache:
            try:
                key_cache[version] = kms_client.get_crypto_key_version(name=version).state.name
            except exceptions.GoogleAPICallError:
                key_cache[version] = None

        content_crc = None
        if args.verify_content and google_crc32c:
            content_crc = crc32c_of(blob.download_as_bytes())

        obj = {
            "name": blob.name,
            "generation": blob.generation,
            "size": blob.size,
            "storage_class": blob.storage_class,
            "kms_key_name": key or None,
            "created": blob.time_created,
            "crc32c": blob.crc32c,
            "md5": blob.md5_hash,
            "content_crc32c": content_crc,
            "document_type": (blob.metadata or {}).get("document_type"),
        }
        findings = evaluate(obj, expected_key, args.nearline_days, args.coldline_days,
                            args.grace_days, now, key_cache.get(version) if key else None)

        if replica_names is not None:
            if blob.name in replica_names:
                pass
            elif replication_since and blob.time_created < replication_since:
                findings.append(("PASS", "PRE_REPLICATION", "created before the replication job; not expected in secondary"))
            elif now - blob.time_created < REPLICATION_GRACE:
                findings.append(("PENDING", "REPLICA_PENDING", "recent object, replica may still be in flight"))
            else:
                findings.append(("WARN", "REPLICA_MISSING", "no object with this name in the secondary bucket"))

        obj["created"] = blob.time_created.isoformat()
        obj["age_days"] = round((now - blob.time_created).total_seconds() / 86400, 2)
        obj["expected_class"] = expected_class(obj["age_days"], args.nearline_days, args.coldline_days)
        obj["key_version_state"] = key_cache.get(version) if key else None
        obj["findings"] = [{"status": s, "code": c, "detail": d} for s, c, d in findings]
        obj["status"] = overall(findings)
        records.append(obj)

    return {
        "bucket": bucket_name,
        "location": bucket.location,
        "default_kms_key": bucket.default_kms_key_name,
        "expected_kms_key": expected_key,
        "objects": records,
        "summary": {
            "objects": len(records),
            "bytes": sum(r["size"] or 0 for r in records),
            "by_status": dict(Counter(r["status"] for r in records)),
            "by_storage_class": dict(Counter(r["storage_class"] for r in records)),
            "by_key": dict(Counter((r["kms_key_name"] or "GOOGLE_MANAGED").split("/cryptoKeys/")[-1].split("/")[0] for r in records)),
        },
    }


# ---------------------------------------------------------------- output

def print_summary(report):
    print(f"\nIntegrity audit  {report['generated_at']}")
    print(f"Auditor          {report['auditor']}")
    print(f"Policy           NEARLINE at {report['policy']['nearline_days']}d, COLDLINE at {report['policy']['coldline_days']}d, "
          f"grace {report['policy']['grace_days']}d, content verified: {report['policy']['verify_content']}")
    for b in report["buckets"]:
        s = b["summary"]
        print(f"\ngs://{b['bucket']}  ({b['location']})")
        print(f"  objects {s['objects']}, bytes {s['bytes']}")
        print(f"  status  {s['by_status']}")
        print(f"  class   {s['by_storage_class']}")
        print(f"  key     {s['by_key']}")
        print(f"  {'STATUS':<8} {'CLASS':<9} {'AGE(d)':>7}  {'KEY':<22} OBJECT")
        for o in b["objects"]:
            key = (o["kms_key_name"] or "GOOGLE_MANAGED").split("/cryptoKeys/")[-1]
            key = key.replace("/cryptoKeyVersions/", " v")
            print(f"  {o['status']:<8} {o['storage_class']:<9} {o['age_days']:>7.2f}  {key:<22} {o['name']}")
            for f in o["findings"]:
                if f["status"] != "PASS":
                    print(f"           - {f['status']} {f['code']}: {f['detail']}")
    t = report["totals"]
    print(f"\nTotals: {t['objects']} objects, PASS {t.get('PASS', 0)}, PENDING {t.get('PENDING', 0)}, "
          f"WARN {t.get('WARN', 0)}, FAIL {t.get('FAIL', 0)}")
    print(f"Report: {report['report_path']}")
    print(f"Result: {'NON-COMPLIANT' if t.get('FAIL', 0) else 'COMPLIANT'}")


def parse_pairs(values, flag):
    pairs = {}
    for v in values or []:
        if "=" not in v:
            raise ValueError(f"{flag} expects NAME=VALUE, got {v!r}")
        k, val = v.split("=", 1)
        pairs[k] = val
    return pairs


def main(argv=None):
    p = argparse.ArgumentParser(description="Integrity audit for archive buckets")
    p.add_argument("--project", required=True)
    p.add_argument("--bucket", action="append", required=True, metavar="BUCKET=KEY_ID",
                   help="bucket to audit and the CMEK key its objects must use (repeatable)")
    p.add_argument("--replica", action="append", metavar="PRIMARY=SECONDARY",
                   help="check every object in PRIMARY has a copy in SECONDARY")
    p.add_argument("--replication-since", help="ISO time the replication job was created")
    p.add_argument("--impersonate", help="service account to run the audit as")
    p.add_argument("--nearline-days", type=int, default=30)
    p.add_argument("--coldline-days", type=int, default=90)
    p.add_argument("--grace-days", type=float, default=1.0, help="lifecycle runs asynchronously, allow this much lag")
    p.add_argument("--verify-content", action="store_true",
                   help="download each object and recompute CRC32C (incurs retrieval fees on Nearline/Coldline)")
    p.add_argument("--report", default=None, help="JSON report path (default reports/audit-<timestamp>.json)")
    args = p.parse_args(argv)

    try:
        buckets = parse_pairs(args.bucket, "--bucket")
        replicas = parse_pairs(args.replica, "--replica")
        since = dt.datetime.fromisoformat(args.replication_since.replace("Z", "+00:00")) if args.replication_since else None
        now = dt.datetime.now(dt.timezone.utc)

        creds, auditor = build_credentials(args.impersonate)
        client = storage.Client(project=args.project, credentials=creds)
        kms_client = kms.KeyManagementServiceClient(credentials=creds)

        key_cache, results = {}, []
        for name, key in buckets.items():
            replica_names = None
            if name in replicas:
                replica_names = {b.name for b in client.list_blobs(replicas[name])}
            results.append(audit_bucket(client, kms_client, name, key, args, now, key_cache, replica_names, since))

        totals = Counter()
        for b in results:
            totals.update(b["summary"]["by_status"])
        totals["objects"] = sum(b["summary"]["objects"] for b in results)

        path = args.report or os.path.join("reports", f"audit-{now.strftime('%Y%m%dT%H%M%SZ')}.json")
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        report = {
            "generated_at": now.isoformat(),
            "project": args.project,
            "auditor": auditor,
            "policy": {"nearline_days": args.nearline_days, "coldline_days": args.coldline_days,
                       "grace_days": args.grace_days, "verify_content": bool(args.verify_content and google_crc32c)},
            "buckets": results,
            "totals": dict(totals),
            "report_path": path,
        }
        with open(path, "w") as fh:
            json.dump(report, fh, indent=2, default=str)

        print_summary(report)
        return 1 if totals.get("FAIL", 0) else 0

    except exceptions.NotFound as err:
        print(f"ERROR: not found: {err.message}", file=sys.stderr)
    except exceptions.Forbidden as err:
        print(f"ERROR: permission denied: {err.message}", file=sys.stderr)
    except google.auth.exceptions.GoogleAuthError as err:
        print(f"ERROR: authentication failed: {err}", file=sys.stderr)
    except exceptions.GoogleAPICallError as err:
        print(f"ERROR: API call failed: {err}", file=sys.stderr)
    except (ValueError, OSError) as err:
        print(f"ERROR: {err}", file=sys.stderr)
    except Exception as err:  # last line of defence: the audit must never crash with a traceback
        print(f"ERROR: unexpected {err.__class__.__name__}: {err}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
