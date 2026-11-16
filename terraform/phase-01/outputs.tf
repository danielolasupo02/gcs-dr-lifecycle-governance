output "project_id" {
  value = data.google_project.this.project_id
}

output "project_number" {
  description = "Needed in phase 04 to build the GCS service agent email for CMEK grants"
  value       = data.google_project.this.number
}

output "gcs_service_agent" {
  description = "Cloud Storage service agent; gets roles/cloudkms.cryptoKeyEncrypterDecrypter in phase 04"
  value       = "service-${data.google_project.this.number}@gs-project-accounts.iam.gserviceaccount.com"
}

output "enabled_apis" {
  value = sort([for s in google_project_service.required : s.service])
}
