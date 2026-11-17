"""Phase 06: upload a handful of synthetic archive documents so the audit has realistic content.

Every document is clearly marked SYNTHETIC and contains no real customer data. Runs as you
(Application Default Credentials), not as the auditor, because the auditor is read-only.

Usage: python scripts/phase-06/seed_documents.py <project-id> <primary-bucket>
"""
import datetime as dt
import sys

from google.api_core import exceptions
from google.cloud import storage

DOCUMENTS = [
    ("statements/2026/11/acct-1001-statement.txt", "statement"),
    ("statements/2026/11/acct-1002-statement.txt", "statement"),
    ("kyc/customer-2001/id-verification.txt", "kyc"),
    ("kyc/customer-2002/proof-of-address.txt", "kyc"),
    ("loans/loan-3001/agreement.txt", "loan_agreement"),
    ("audit/2026-q4/access-review.txt", "internal_audit"),
]


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    project, bucket_name = argv[1:]
    bucket = storage.Client(project=project).bucket(bucket_name)
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    try:
        for name, doc_type in DOCUMENTS:
            body = (
                "SYNTHETIC TEST DOCUMENT - NOT REAL CUSTOMER DATA\n"
                f"document_type: {doc_type}\npath: {name}\nseeded_at: {now}\n"
            )
            blob = bucket.blob(name)
            blob.metadata = {"document_type": doc_type, "synthetic": "true"}
            blob.upload_from_string(body, content_type="text/plain")
            print(f"  uploaded gs://{bucket_name}/{name}")
    except exceptions.GoogleAPICallError as err:
        print(f"ERROR: {err.__class__.__name__}: {err.message}")
        return 1
    print(f"Seeded {len(DOCUMENTS)} documents. They replicate to the secondary bucket within minutes.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
