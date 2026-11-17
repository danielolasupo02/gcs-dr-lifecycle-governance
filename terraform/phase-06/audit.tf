# Phase 06: a read-only identity for the integrity audit.
#
# The audit script runs as this service account through impersonation, not as the project
# owner. If the audit ever tried to change something, Google would refuse it, and the
# report reflects exactly what a least-privilege auditor can see.

resource "google_service_account" "auditor" {
  project      = var.project_id
  account_id   = "storage-auditor"
  display_name = "Storage integrity auditor (read-only)"
  description  = "Runs scripts/phase-06/audit_storage.py against the archive buckets"

  depends_on = [google_project_service.required]
}

locals {
  auditor_member = "serviceAccount:${google_service_account.auditor.email}"

  audited_buckets = {
    primary   = google_storage_bucket.primary.name
    secondary = google_storage_bucket.secondary.name
  }
  audited_keys = {
    primary   = google_kms_crypto_key.archive_primary.id
    secondary = google_kms_crypto_key.archive_secondary.id
  }
}

# List and read object metadata. objectViewer also allows reading object content, which
# the optional --verify-content checksum pass needs.
resource "google_storage_bucket_iam_member" "auditor_object_viewer" {
  for_each = local.audited_buckets

  bucket = each.value
  role   = "roles/storage.objectViewer"
  member = local.auditor_member
}

# Read bucket metadata (location, default key, enforcement config).
resource "google_storage_bucket_iam_member" "auditor_bucket_reader" {
  for_each = local.audited_buckets

  bucket = each.value
  role   = "roles/storage.legacyBucketReader"
  member = local.auditor_member
}

# See key version state, so the audit can flag objects encrypted with a disabled or
# destroyed version. Viewer cannot encrypt, decrypt or change the key.
resource "google_kms_crypto_key_iam_member" "auditor_kms_viewer" {
  for_each = local.audited_keys

  crypto_key_id = each.value
  role          = "roles/cloudkms.viewer"
  member        = local.auditor_member
}

# Who may run the audit as this account.
resource "google_service_account_iam_member" "auditor_impersonators" {
  for_each = toset(var.auditor_impersonators)

  service_account_id = google_service_account.auditor.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = each.value
}
