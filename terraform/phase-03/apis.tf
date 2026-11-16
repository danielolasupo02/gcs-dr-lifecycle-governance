# Carried forward from phase 01 (moved out of main.tf). Same resource addresses, so the
# state copied from phase-01 adopts these without changes.

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_project_service" "required" {
  for_each = var.required_apis

  project = var.project_id
  service = each.value

  disable_on_destroy         = false
  disable_dependent_services = false
}
