# ---------- Project ----------

variable "project_id" {
  type        = string
  description = "GCP project ID that hosts the fintech archive"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be 6-30 chars, lowercase letters, digits or hyphens, start with a letter."
  }
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
    "pubsub.googleapis.com", # phase 05: replication change notifications
  ]
}

# ---------- Regions ----------

variable "region_primary" {
  type        = string
  description = "Primary region for bucket deployment"
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region_primary))
    error_message = "region_primary must be a lowercase GCP region such as us-central1."
  }
}

variable "region_secondary" {
  type        = string
  description = "Secondary region for the DR replica; must differ from region_primary"
  default     = "us-east1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region_secondary))
    error_message = "region_secondary must be a lowercase GCP region such as us-east1."
  }
}

# ---------- Lifecycle thresholds ----------

variable "nearline_age_days" {
  type        = number
  description = "Object age in days before transition from STANDARD to NEARLINE"
  default     = 30

  validation {
    condition     = var.nearline_age_days >= 1
    error_message = "nearline_age_days must be at least 1."
  }
}

variable "coldline_age_days" {
  type        = number
  description = "Object age in days before transition from NEARLINE to COLDLINE"
  default     = 90

  validation {
    condition     = var.coldline_age_days >= 1
    error_message = "coldline_age_days must be at least 1."
  }
}

variable "noncurrent_version_retention_days" {
  type        = number
  description = "Days a noncurrent (overwritten or deleted) object version is kept before deletion"
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 1
    error_message = "noncurrent_version_retention_days must be at least 1."
  }
}

variable "abort_incomplete_upload_days" {
  type        = number
  description = "Days before an unfinished multipart upload is aborted"
  default     = 7

  validation {
    condition     = var.abort_incomplete_upload_days >= 1
    error_message = "abort_incomplete_upload_days must be at least 1."
  }
}

variable "soft_delete_retention_days" {
  type        = number
  description = "Soft delete window in days; 0 disables, otherwise 7 to 90"
  default     = 7

  validation {
    condition     = var.soft_delete_retention_days == 0 || (var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90)
    error_message = "soft_delete_retention_days must be 0 or between 7 and 90."
  }
}

# ---------- Safety and metadata ----------

variable "force_destroy" {
  type        = bool
  description = "Allow terraform destroy to delete buckets that still hold objects. Keep false outside teardown."
  default     = false
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to every bucket"
  default = {
    workload            = "fintech-archive"
    data_classification = "confidential"
    environment         = "lab"
  }
}

# ---------- Encryption (phase 04) ----------

variable "kms_key_ring_name" {
  type        = string
  description = "Key ring name, created once in each bucket region. Key rings can never be deleted."
  default     = "fintech-archive-ring"
}

variable "kms_rotation_days" {
  type        = number
  description = "Automatic rotation period for the CMEK keys, in days"
  default     = 90

  validation {
    condition     = var.kms_rotation_days >= 1 && var.kms_rotation_days <= 365
    error_message = "kms_rotation_days must be between 1 and 365."
  }
}

variable "kms_protection_level" {
  type        = string
  description = "SOFTWARE or HSM. HSM keys cost more and are FIPS 140-2 Level 3."
  default     = "SOFTWARE"

  validation {
    condition     = contains(["SOFTWARE", "HSM"], var.kms_protection_level)
    error_message = "kms_protection_level must be SOFTWARE or HSM."
  }
}

# ---------- Replication (phase 05) ----------

variable "replication_overwrite_when" {
  type        = string
  description = "When the replication job overwrites an object that already exists in the secondary bucket"
  default     = "DIFFERENT"

  validation {
    condition     = contains(["ALWAYS", "DIFFERENT", "NEVER"], var.replication_overwrite_when)
    error_message = "replication_overwrite_when must be ALWAYS, DIFFERENT or NEVER."
  }
}
