# Phase 08 (stretch goal): Cloud Storage access logs in BigQuery for cost and security analysis.
#
#   1. Data Access audit logs are switched on for Cloud Storage. Admin Activity logs
#      (bucket and IAM changes) are always on and need no configuration.
#   2. A log sink routes audit logs for the two archive buckets, and nothing else, into a
#      BigQuery dataset, using one partitioned table per log type.
#   3. The sink's own identity can write to the dataset; the auditor can read and query it.

# ---------- 1. Data Access audit logs for Cloud Storage ----------
# Authoritative for storage.googleapis.com in this project: this resource owns its audit config.

resource "google_project_iam_audit_config" "storage" {
  project = var.project_id
  service = "storage.googleapis.com"

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# ---------- 2. BigQuery dataset ----------

resource "google_bigquery_dataset" "access_logs" {
  project       = var.project_id
  dataset_id    = "gcs_access_logs"
  friendly_name = "GCS archive access logs"
  description   = "Cloud Storage audit logs for the archive buckets, routed by the gcs-archive-access sink"
  location      = "US" # multi-region: receives logs from us-central1 and us-east1 buckets

  # The sink writes date-partitioned tables; each day's partition expires after the retention period.
  default_partition_expiration_ms = var.access_log_retention_days * 86400000

  delete_contents_on_destroy = var.force_destroy

  labels = local.common_labels

  depends_on = [google_project_service.required]
}

# ---------- 3. Log sink ----------

resource "google_logging_project_sink" "gcs_access" {
  project     = var.project_id
  name        = "gcs-archive-access-to-bigquery"
  description = "Audit logs for the archive buckets into BigQuery"
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.access_logs.dataset_id}"

  # Each line is ANDed. Only audit logs, only for the two archive buckets.
  filter = <<-EOT
    logName:"cloudaudit.googleapis.com"
    resource.type="gcs_bucket"
    resource.labels.bucket_name=("${google_storage_bucket.primary.name}" OR "${google_storage_bucket.secondary.name}")
  EOT

  unique_writer_identity = true

  bigquery_options {
    use_partitioned_tables = true
  }
}

# The sink writes as its own service identity, which needs to create tables and insert rows.
resource "google_bigquery_dataset_iam_member" "sink_writer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.access_logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.gcs_access.writer_identity
}

# ---------- 4. Read access for the auditor ----------

resource "google_bigquery_dataset_iam_member" "auditor_viewer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.access_logs.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = local.auditor_member
}

# Queries run as jobs billed to the project; jobUser allows running them, nothing more.
resource "google_project_iam_member" "auditor_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = local.auditor_member
}
