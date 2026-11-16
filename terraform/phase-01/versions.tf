terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }

  # Local state for phase 01. Remote state (GCS backend) is introduced once buckets exist.
}

provider "google" {
  project = var.project_id
  region  = var.region_primary
}
