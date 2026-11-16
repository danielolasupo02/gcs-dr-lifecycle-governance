variable "project_id" {
  type        = string
  description = "GCP project ID that hosts the fintech archive"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be 6-30 chars, lowercase letters, digits or hyphens, start with a letter."
  }
}

variable "region_primary" {
  type        = string
  description = "Default region for the provider"
  default     = "us-central1"
}

variable "required_apis" {
  type        = set(string)
  description = "APIs this project depends on across all phases"
  default = [
    "storage-component.googleapis.com",
    "storage.googleapis.com",
    "serviceusage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "cloudkms.googleapis.com",
    "storagetransfer.googleapis.com",
    "logging.googleapis.com",
    "bigquery.googleapis.com",
    "monitoring.googleapis.com",
  ]
}
