"""Phase 07: end-to-end validation of the deployed archive.

1. Upload a test document (version 1) to the primary bucket.
2. Confirm it replicates to the secondary region, encrypted with the secondary key.
3. Upload a second revision of the same document (version 2).
4. Confirm version 2 replicates, and that BOTH buckets keep version 1 as a noncurrent
   generation that can still be read.

Usage: python scripts/phase-07/validate_deployment.py <project> <primary> <secondary> <primary-key> <secondary-key>
"""
import datetime as dt
import os
import sys

from google.api_core import exceptions
from google.cloud import storage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from archive_lib import check, print_versions, summary, versions, wait_for  # noqa: E402

DOC = "validation/test-document.txt"


def body(version):
    ts = dt.datetime.now(dt.timezone.utc).isoformat()
    return (f"TEST DOCUMENT version {version}\nSYNTHETIC - NOT REAL CUSTOMER DATA\nwritten_at: {ts}\n").encode()


def upload(bucket, version):
    blob = bucket.blob(DOC)
    blob.metadata = {"document_type": "validation", "synthetic": "true", "revision": str(version)}
    data = body(version)
    blob.upload_from_string(data, content_type="text/plain")
    blob.reload()
    print(f"  uploaded version {version} to gs://{bucket.name}/{DOC} (generation {blob.generation})")
    return data, blob.generation


def main(argv):
    if len(argv) != 6:
        print(__doc__)
        return 2
    project, p_name, s_name, p_key, s_key = argv[1:]
    client = storage.Client(project=project)
    primary, secondary = client.bucket(p_name), client.bucket(s_name)

    try:
        print("\nStep 1-2: first version replicates to the secondary region")
        v1, gen1 = upload(primary, 1)
        secs, replica = wait_for(secondary, DOC, v1, "version 1 replica")
        check(f"version 1 replicated ({secs}s)" if secs is not None else "version 1 replicated", secs is not None)
        if replica:
            check("replica encrypted with secondary key", (replica.kms_key_name or "").startswith(s_key + "/"))

        print("\nStep 3-4: second revision replicates and versioning keeps the first")
        v2, gen2 = upload(primary, 2)
        check("second revision got a new generation", gen2 != gen1)
        secs, _ = wait_for(secondary, DOC, v2, "version 2 replica")
        check(f"version 2 replicated ({secs}s)" if secs is not None else "version 2 replicated", secs is not None)

        p_versions = versions(client, primary, DOC)
        p_gen1 = next((b for b in p_versions if b.generation == gen1), None)
        check("primary: version 1 kept as noncurrent", p_gen1 is not None and p_gen1.time_deleted is not None)
        check("primary: version 1 content still readable", p_gen1 is not None and p_gen1.download_as_bytes() == v1)
        check("primary: live content is version 2", primary.get_blob(DOC).download_as_bytes() == v2)
        check("primary: every version uses the primary key",
              all((b.kms_key_name or "").startswith(p_key + "/") for b in p_versions))

        s_versions = versions(client, secondary, DOC)
        s_old = [b for b in s_versions if b.time_deleted is not None and b.download_as_bytes() == v1]
        check("secondary: version 1 kept as noncurrent", bool(s_old))
        check("secondary: live content is version 2", secondary.get_blob(DOC).download_as_bytes() == v2)
        check("secondary: every version uses the secondary key",
              all((b.kms_key_name or "").startswith(s_key + "/") for b in s_versions))

        print("\nVersion history")
        print_versions(client, primary, DOC)
        print_versions(client, secondary, DOC)
    except exceptions.GoogleAPICallError as err:
        check(f"API call failed: {err.__class__.__name__}: {err.message[:100]}", False)

    return summary("Deployment validation")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
