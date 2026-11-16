"""Phase 01: prove the Python client library can reach GCS using ADC.

Usage: python scripts/phase-01/verify_python_auth.py <project-id>
Exit 0 on success, 1 on any auth or permission problem.
"""
import sys

import google.auth
from google.api_core import exceptions
from google.auth.exceptions import DefaultCredentialsError
from google.cloud import storage


def main(project_id: str) -> int:
    try:
        creds, adc_project = google.auth.default()
    except DefaultCredentialsError as err:
        print(f"[FAIL] No Application Default Credentials: {err}")
        return 1

    principal = getattr(creds, "service_account_email", None) or "user credentials"
    print(f"ADC principal     : {principal}")
    print(f"ADC quota project : {getattr(creds, 'quota_project_id', None)}")
    print(f"ADC default proj  : {adc_project}")

    try:
        client = storage.Client(project=project_id)
        buckets = [b.name for b in client.list_buckets(max_results=10)]
    except exceptions.Forbidden as err:
        print(f"[FAIL] 403 from Storage API (API disabled or missing IAM?): {err.message}")
        return 1
    except exceptions.NotFound as err:
        print(f"[FAIL] 404, project not found: {err.message}")
        return 1
    except exceptions.GoogleAPICallError as err:
        print(f"[FAIL] Storage API error: {err}")
        return 1

    print(f"[PASS] Storage API reachable in {project_id}; {len(buckets)} bucket(s) visible")
    for name in buckets:
        print(f"  - {name}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
