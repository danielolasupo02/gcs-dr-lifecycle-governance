terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }

  # Local state, carried forward from phase-01 by copying terraform.tfstate into this folder.
}

provider "google" {
  project = var.project_id
  region  = var.region_primary

  # Bill API quota to this project explicitly, instead of whatever quota project the
  # shell or ADC file happens to carry (Cloud Shell can carry a deleted lab project).
  billing_project       = var.project_id
  user_project_override = true
}
