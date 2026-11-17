#!/usr/bin/env bash
# Phase 07: tear the lab down. DESTRUCTIVE AND NOT REVERSIBLE AFTER 30 DAYS.
#
# What it does:
#   1. Sets force_destroy=true on both buckets (they hold versioned objects).
#   2. Removes the KMS keys and key rings from Terraform state. They have prevent_destroy,
#      and Cloud KMS cannot delete them anyway.
#   3. terraform destroy: buckets, replication job, IAM, auditor account.
#   4. Schedules every enabled version of both keys for destruction (30-day window) and
#      stops rotation, so the keys stop costing money.
#
# Key rings and key names stay in the project forever. Deleting the whole project
# (gcloud projects delete) is the alternative that removes everything.
#
# Usage: ./scripts/phase-07/teardown.sh --yes-destroy <project-id>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-07"

if [[ "${1:-}" != "--yes-destroy" || -z "${2:-}" ]]; then
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
PROJECT_ID="$2"
CURRENT="$(terraform -chdir="$TF_DIR" output -raw project_id 2>/dev/null)"
[[ "$PROJECT_ID" != "$CURRENT" ]] && { echo "Refusing: $PROJECT_ID does not match Terraform project $CURRENT"; exit 1; }

KEYS=("$(terraform -chdir="$TF_DIR" output -raw kms_key_primary)" "$(terraform -chdir="$TF_DIR" output -raw kms_key_secondary)")

echo "Tearing down $PROJECT_ID in 10 seconds. Ctrl+C to abort."
sleep 10

echo "1/4 allow bucket deletion"
terraform -chdir="$TF_DIR" apply -input=false -auto-approve -var force_destroy=true || exit 1

echo "2/4 remove keys from Terraform state"
for r in google_kms_crypto_key.archive_primary google_kms_crypto_key.archive_secondary \
         google_kms_key_ring.archive_ring_primary google_kms_key_ring.archive_ring_secondary; do
  terraform -chdir="$TF_DIR" state rm "$r"
done

echo "3/4 terraform destroy"
terraform -chdir="$TF_DIR" destroy -input=false -auto-approve -var force_destroy=true || exit 1

echo "4/4 schedule key version destruction and stop rotation"
for key in "${KEYS[@]}"; do
  gcloud kms keys update "$key" --remove-rotation-schedule >/dev/null
  for v in $(gcloud kms keys versions list --key="$key" --filter="state=ENABLED" --format="value(name)"); do
    gcloud kms keys versions destroy "$v" --quiet >/dev/null && echo "  scheduled destruction: ${v##*/cryptoKeys/}"
  done
done

echo "Done. Key rings remain (Cloud KMS never deletes them). APIs stay enabled (disable_on_destroy=false)."
