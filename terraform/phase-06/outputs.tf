output "project_id" {
  value = data.google_project.this.project_id
}

output "project_number" {
  value = data.google_project.this.number
}

output "gcs_service_agent" {
  description = "Cloud Storage service agent; gets roles/cloudkms.cryptoKeyEncrypterDecrypter in phase 04"
  value       = "service-${data.google_project.this.number}@gs-project-accounts.iam.gserviceaccount.com"
}

output "enabled_apis" {
  value = sort([for s in google_project_service.required : s.service])
}

output "primary_bucket_name" {
  value = google_storage_bucket.primary.name
}

output "primary_bucket_url" {
  value = google_storage_bucket.primary.url
}

output "primary_region" {
  value = lower(google_storage_bucket.primary.location)
}

output "secondary_bucket_name" {
  value = google_storage_bucket.secondary.name
}

output "secondary_bucket_url" {
  value = google_storage_bucket.secondary.url
}

output "secondary_region" {
  value = lower(google_storage_bucket.secondary.location)
}

output "nearline_age_days" {
  value = var.nearline_age_days
}

output "coldline_age_days" {
  value = var.coldline_age_days
}

output "kms_key_primary" {
  value = google_kms_crypto_key.archive_primary.id
}

output "kms_key_secondary" {
  value = google_kms_crypto_key.archive_secondary.id
}

output "gcs_service_agent_email" {
  description = "Service agent that holds cryptoKeyEncrypterDecrypter on both keys"
  value       = data.google_storage_project_service_account.gcs.email_address
}

output "replication_job_name" {
  description = "Google-assigned name of the cross-bucket replication job (transferJobs/<id>)"
  value       = google_storage_transfer_job.primary_to_secondary.name
}

output "sts_service_agent_email" {
  value = data.google_storage_transfer_project_service_account.sts.email
}

output "auditor_service_account_email" {
  value = google_service_account.auditor.email
}
