# Phase 02: primary archive bucket and secondary DR bucket in separate regions.
# Storage class transitions (NEARLINE, COLDLINE) are added in phase 03, CMEK in phase 04,
# and the replication job between these two buckets in phase 05.

locals {
  # Bucket names are global across all GCP customers; the project ID makes them unique.
  primary_bucket_name   = "${var.project_id}-primary"
  secondary_bucket_name = "${var.project_id}-secondary"

  common_labels = merge(var.labels, { managed_by = "terraform" })
}

resource "google_storage_bucket" "primary" {
  name          = local.primary_bucket_name
  project       = var.project_id
  location      = upper(var.region_primary)
  storage_class = "STANDARD"
  force_destroy = var.force_destroy

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  labels = merge(local.common_labels, { role = "primary" })

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = var.soft_delete_retention_days * 86400
  }

  # Cost governance for versioning: overwritten or deleted versions are kept for
  # noncurrent_version_retention_days, then removed. Live objects are never touched by this rule.
  lifecycle_rule {
    condition {
      days_since_noncurrent_time = var.noncurrent_version_retention_days
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = var.abort_incomplete_upload_days
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket" "secondary" {
  name          = local.secondary_bucket_name
  project       = var.project_id
  location      = upper(var.region_secondary)
  storage_class = "STANDARD"
  force_destroy = var.force_destroy

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  labels = merge(local.common_labels, { role = "secondary" })

  # Versioned too, so a bad overwrite replicated from primary is still recoverable here.
  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = var.soft_delete_retention_days * 86400
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = var.noncurrent_version_retention_days
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = var.abort_incomplete_upload_days
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  lifecycle {
    precondition {
      condition     = lower(var.region_secondary) != lower(var.region_primary)
      error_message = "region_secondary must differ from region_primary, otherwise the replica gives no regional DR."
    }
  }

  depends_on = [google_project_service.required]
}
