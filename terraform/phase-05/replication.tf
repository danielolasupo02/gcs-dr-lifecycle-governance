# Phase 05: cross-bucket replication from primary (us-central1) to secondary (us-east1).
#
# google_storage_bucket has no replication block. Cross-bucket replication is a Storage
# Transfer Service job with a replication_spec: Cloud Storage publishes a Pub/Sub
# notification for every new or updated object in the primary bucket, and the transfer
# job copies that object to the secondary bucket, usually within minutes.
#
# Not replicated (by design of the service): objects that existed before the job was
# created, deletions, noncurrent versions, and lifecycle configuration. Each bucket keeps
# its own lifecycle rules and CMEK key; replicated objects are encrypted with the
# secondary bucket's default key.

data "google_storage_transfer_project_service_account" "sts" {
  project = var.project_id
}

locals {
  sts_member = "serviceAccount:${data.google_storage_transfer_project_service_account.sts.email}"
  gcs_member = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# ---------- Storage Transfer Service agent: source bucket ----------
# Reads objects and manages the Pub/Sub notification config on the source bucket.

resource "google_storage_bucket_iam_member" "sts_source_bucket_owner" {
  bucket = google_storage_bucket.primary.name
  role   = "roles/storage.legacyBucketOwner"
  member = local.sts_member
}

resource "google_storage_bucket_iam_member" "sts_source_object_viewer" {
  bucket = google_storage_bucket.primary.name
  role   = "roles/storage.objectViewer"
  member = local.sts_member
}

# ---------- Storage Transfer Service agent: destination bucket ----------
# Writes replicated objects. objectUser is the role the docs require; it includes object
# delete, but replication never deletes, and the agent gets no bucket admin role here.

resource "google_storage_bucket_iam_member" "sts_sink_object_user" {
  bucket = google_storage_bucket.secondary.name
  role   = "roles/storage.objectUser"
  member = local.sts_member
}

resource "google_storage_bucket_iam_member" "sts_sink_bucket_reader" {
  bucket = google_storage_bucket.secondary.name
  role   = "roles/storage.legacyBucketReader"
  member = local.sts_member
}

# ---------- Pub/Sub for change notifications ----------

# The transfer service creates and consumes the topic and subscription.
resource "google_project_iam_member" "sts_pubsub_editor" {
  project = var.project_id
  role    = "roles/pubsub.editor"
  member  = local.sts_member
}

# Cloud Storage publishes object change events to that topic.
resource "google_project_iam_member" "gcs_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = local.gcs_member
}

# ---------- Replication job ----------
# Cross-bucket replication jobs do not accept a custom name; Google assigns transferJobs/<id>.

resource "google_storage_transfer_job" "primary_to_secondary" {
  project     = var.project_id
  description = "DR replication ${google_storage_bucket.primary.name} to ${google_storage_bucket.secondary.name}"
  status      = "ENABLED"

  replication_spec {
    gcs_data_source {
      bucket_name = google_storage_bucket.primary.name
    }

    gcs_data_sink {
      bucket_name = google_storage_bucket.secondary.name
    }

    transfer_options {
      overwrite_when = var.replication_overwrite_when
    }
  }

  depends_on = [
    google_project_service.required,
    google_storage_bucket_iam_member.sts_source_bucket_owner,
    google_storage_bucket_iam_member.sts_source_object_viewer,
    google_storage_bucket_iam_member.sts_sink_object_user,
    google_storage_bucket_iam_member.sts_sink_bucket_reader,
    google_project_iam_member.sts_pubsub_editor,
    google_project_iam_member.gcs_pubsub_publisher,
  ]
}
