# Phase 01: put API enablement under Terraform so it is declared, not just clicked.
# setup_env.sh enables the same APIs with gcloud first (Terraform needs serviceusage to be on).
# This makes the state the source of truth and detects drift if someone disables an API.

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_project_service" "required" {
  for_each = var.required_apis

  project = var.project_id
  service = each.value

  # Never switch APIs off on destroy. Disabling storage on a live archive project would be an outage.
  disable_on_destroy         = false
  disable_dependent_services = false
}
