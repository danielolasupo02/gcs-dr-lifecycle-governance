# Phase 04: customer-managed encryption keys (CMEK) for both archive buckets.
#
# A CMEK key must live in the same location as the bucket it encrypts, so there is one key
# ring and one key per bucket region: us-central1 for primary, us-east1 for secondary.
#
# Key rings and keys cannot be deleted in Cloud KMS. Destroying a key only schedules its
# versions for destruction, and the names stay taken forever. prevent_destroy stops a
# routine terraform destroy from turning the archive into unreadable ciphertext.

# The Cloud Storage service agent encrypts and decrypts on the bucket's behalf.
# This data source also creates the agent if the project has never used it.
data "google_storage_project_service_account" "gcs" {
  project = var.project_id
}

# ---------- Primary region ----------

resource "google_kms_key_ring" "archive_ring_primary" {
  name     = var.kms_key_ring_name
  project  = var.project_id
  location = var.region_primary

  depends_on = [google_project_service.required]
}

resource "google_kms_crypto_key" "archive_primary" {
  name            = "archive-primary"
  key_ring        = google_kms_key_ring.archive_ring_primary.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "${var.kms_rotation_days * 86400}s"

  # Window in which a destroyed key version can still be restored.
  destroy_scheduled_duration = "2592000s" # 30 days

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = var.kms_protection_level
  }

  labels = merge(local.common_labels, { role = "primary" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "gcs_primary" {
  crypto_key_id = google_kms_crypto_key.archive_primary.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# ---------- Secondary region ----------

resource "google_kms_key_ring" "archive_ring_secondary" {
  name     = var.kms_key_ring_name
  project  = var.project_id
  location = var.region_secondary

  depends_on = [google_project_service.required]
}

resource "google_kms_crypto_key" "archive_secondary" {
  name            = "archive-secondary"
  key_ring        = google_kms_key_ring.archive_ring_secondary.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "${var.kms_rotation_days * 86400}s"

  destroy_scheduled_duration = "2592000s" # 30 days

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = var.kms_protection_level
  }

  labels = merge(local.common_labels, { role = "secondary" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "gcs_secondary" {
  crypto_key_id = google_kms_crypto_key.archive_secondary.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}
