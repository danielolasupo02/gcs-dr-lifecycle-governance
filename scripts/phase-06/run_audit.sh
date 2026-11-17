#!/usr/bin/env bash
# Phase 06: run the integrity audit as the read-only storage-auditor service account.
# Buckets, keys and the auditor come from Terraform outputs, so nothing is hardcoded.
# Extra arguments are passed through, e.g. --verify-content
# Usage: ./scripts/phase-06/run_audit.sh [--verify-content]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-06"
PY="$REPO_ROOT/.venv/bin/python"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

P_NAME="$(tf_out primary_bucket_name)";   P_KEY="$(tf_out kms_key_primary)"
S_NAME="$(tf_out secondary_bucket_name)"; S_KEY="$(tf_out kms_key_secondary)"
AUDITOR="$(tf_out auditor_service_account_email)"
JOB="$(tf_out replication_job_name)"
SINCE="$(gcloud transfer jobs describe "$JOB" --project="$PROJECT_ID" --format='value(creationTime)' 2>/dev/null)"

cd "$REPO_ROOT"
exec "$PY" "$SCRIPT_DIR/audit_storage.py" \
  --project "$PROJECT_ID" \
  --bucket "$P_NAME=$P_KEY" \
  --bucket "$S_NAME=$S_KEY" \
  --replica "$P_NAME=$S_NAME" \
  ${SINCE:+--replication-since "$SINCE"} \
  --nearline-days "$(tf_out nearline_age_days)" \
  --coldline-days "$(tf_out coldline_age_days)" \
  --impersonate "$AUDITOR" \
  "$@"
