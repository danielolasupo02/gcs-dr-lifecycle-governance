"""Prometheus exporter: estimated monthly storage cost of the archive buckets.

Every COLLECT_INTERVAL_S it lists every object version in each bucket (live and
noncurrent, both are billed), sums bytes per bucket, storage class and state, and prices
them per GiB-month. Listing is used instead of the Cloud Monitoring total_bytes metric
because that metric is only measured once a day.

Runs as the read-only storage-auditor service account (IMPERSONATE_SA).

Environment:
  PROJECT_ID, BUCKETS (comma separated), IMPERSONATE_SA (optional)
  COST_THRESHOLD_USD     exposed as gcs_cost_threshold_usd for the alert rule (default 10)
  COLLECT_INTERVAL_S     default 120
  PRICE_STANDARD, PRICE_NEARLINE, PRICE_COLDLINE, PRICE_ARCHIVE   USD per GiB-month
"""
import logging
import os
import time
from collections import defaultdict

import google.auth
from google.auth import impersonated_credentials
from google.cloud import storage
from prometheus_client import Counter, Gauge, start_http_server

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("gcs-cost-exporter")

GIB = 1024 ** 3
SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]
PRICES = {  # approximate US regional list prices, USD per GiB-month; override per region
    "STANDARD": float(os.getenv("PRICE_STANDARD", "0.020")),
    "NEARLINE": float(os.getenv("PRICE_NEARLINE", "0.010")),
    "COLDLINE": float(os.getenv("PRICE_COLDLINE", "0.004")),
    "ARCHIVE": float(os.getenv("PRICE_ARCHIVE", "0.0012")),
}

BYTES = Gauge("gcs_bucket_bytes", "Bytes stored, by bucket, storage class and version state",
              ["bucket", "storage_class", "state"])
OBJECTS = Gauge("gcs_bucket_objects", "Object versions stored, by bucket, storage class and version state",
                ["bucket", "storage_class", "state"])
COST = Gauge("gcs_estimated_monthly_storage_cost_usd", "Estimated monthly storage cost, by bucket and storage class",
             ["bucket", "storage_class"])
TOTAL = Gauge("gcs_estimated_monthly_storage_cost_usd_total", "Estimated monthly storage cost across all audited buckets")
THRESHOLD = Gauge("gcs_cost_threshold_usd", "Monthly storage cost above which GCSStorageCostAboveThreshold fires")
PRICE = Gauge("gcs_price_per_gib_month_usd", "Price used for the estimate", ["storage_class"])
LAST_SUCCESS = Gauge("gcs_cost_exporter_last_success_timestamp_seconds", "Unix time of the last successful collection")
DURATION = Gauge("gcs_cost_exporter_collect_duration_seconds", "Duration of the last collection")
ERRORS = Counter("gcs_cost_exporter_errors_total", "Failed collections")


def make_client(project, impersonate):
    source, _ = google.auth.default(scopes=SCOPES)
    creds = source
    if impersonate:
        creds = impersonated_credentials.Credentials(
            source_credentials=source, target_principal=impersonate, target_scopes=SCOPES, lifetime=3600
        )
    return storage.Client(project=project, credentials=creds)


def collect(client, buckets):
    sizes, counts = defaultdict(int), defaultdict(int)
    for bucket in buckets:
        for blob in client.list_blobs(bucket, versions=True):
            key = (bucket, blob.storage_class or "STANDARD", "noncurrent" if blob.time_deleted else "live")
            sizes[key] += blob.size or 0
            counts[key] += 1

    cost = defaultdict(float)
    for (bucket, cls, _), size in sizes.items():
        cost[(bucket, cls)] += size / GIB * PRICES.get(cls, PRICES["STANDARD"])

    BYTES.clear()
    OBJECTS.clear()
    COST.clear()
    for key, size in sizes.items():
        BYTES.labels(*key).set(size)
        OBJECTS.labels(*key).set(counts[key])
    for key, usd in cost.items():
        COST.labels(*key).set(usd)
    TOTAL.set(sum(cost.values()))
    return sum(sizes.values()), sum(cost.values())


def main():
    project = os.environ["PROJECT_ID"]
    buckets = [b.strip() for b in os.environ["BUCKETS"].split(",") if b.strip()]
    interval = int(os.getenv("COLLECT_INTERVAL_S", "120"))
    THRESHOLD.set(float(os.getenv("COST_THRESHOLD_USD", "10")))
    for cls, p in PRICES.items():
        PRICE.labels(cls).set(p)

    start_http_server(int(os.getenv("PORT", "9101")))
    log.info("serving :%s, buckets=%s, threshold=$%s", os.getenv("PORT", "9101"), buckets,
             os.getenv("COST_THRESHOLD_USD", "10"))
    client = make_client(project, os.getenv("IMPERSONATE_SA"))

    while True:
        started = time.monotonic()
        try:
            total_bytes, total_usd = collect(client, buckets)
            LAST_SUCCESS.set_to_current_time()
            log.info("collected %d bytes, estimated $%.8f/month", total_bytes, total_usd)
        except Exception as err:  # keep serving last good values; staleness alert covers this
            ERRORS.inc()
            log.error("collection failed: %s: %s", err.__class__.__name__, err)
        DURATION.set(time.monotonic() - started)
        time.sleep(interval)


if __name__ == "__main__":
    main()
