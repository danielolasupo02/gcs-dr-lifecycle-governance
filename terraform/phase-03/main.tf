# Phase 03: storage class transitions on both buckets.
#   STANDARD -> NEARLINE at var.nearline_age_days (default 30)
#   NEARLINE -> COLDLINE at var.coldline_age_days (default 90)
# Plus the phase 02 housekeeping rules (noncurrent version cleanup, stale upload abort).
# CMEK is added in phase 04 and replication in phase 05.

locals {
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

  # Tier 1: documents older than nearline_age_days move to NEARLINE.
  # Live versions only: a noncurrent version is deleted by the rule below, and moving it
  # to a colder class first would only add a minimum-duration charge.
  lifecycle_rule {
    condition {
      age                   = var.nearline_age_days
      matches_storage_class = ["STANDARD"]
      with_state            = "LIVE"
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  # Tier 2: documents older than coldline_age_days move to COLDLINE.
  # STANDARD is included so an object that missed tier 1 (for example uploaded before
  # this rule existed) still lands in COLDLINE instead of staying hot.
  lifecycle_rule {
    condition {
      age                   = var.coldline_age_days
      matches_storage_class = ["STANDARD", "NEARLINE"]
      with_state            = "LIVE"
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
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
      condition     = var.coldline_age_days > var.nearline_age_days
      error_message = "coldline_age_days must be greater than nearline_age_days, otherwise objects skip NEARLINE entirely."
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

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = var.soft_delete_retention_days * 86400
  }

  # Same tiering on the DR copy; without it the replica would sit in STANDARD forever
  # and cost more than the primary it protects.
  lifecycle_rule {
    condition {
      age                   = var.nearline_age_days
      matches_storage_class = ["STANDARD"]
      with_state            = "LIVE"
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition {
      age                   = var.coldline_age_days
      matches_storage_class = ["STANDARD", "NEARLINE"]
      with_state            = "LIVE"
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
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
