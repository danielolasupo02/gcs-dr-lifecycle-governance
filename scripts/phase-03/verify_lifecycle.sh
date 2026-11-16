#!/usr/bin/env bash
# Phase 03: verify Terraform state and the live lifecycle rules on both buckets. Read-only.
# Usage: ./scripts/phase-03/verify_lifecycle.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-03"
PY="$REPO_ROOT/.venv/bin/python"
PASS=0; FAILED=0

[[ -z "$PROJECT_ID" ]] && { echo "usage: $0 <project-id>"; exit 1; }

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [PASS] %s\n' "$desc"; PASS=$((PASS+1))
  else
    printf '  [FAIL] %s\n' "$desc"; FAILED=$((FAILED+1))
  fi
}

no_drift() {
  terraform -chdir="$TF_DIR" plan -input=false -detailed-exitcode -lock=false >/dev/null 2>&1
}

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null; }

echo "Phase 03 verification for project: $PROJECT_ID"
echo "Run at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo
echo "Terraform"
check "terraform fmt -check"               terraform -chdir="$TF_DIR" fmt -check
check "terraform validate"                 terraform -chdir="$TF_DIR" validate
check "plan shows no drift (exit code 0)"  no_drift

NEARLINE="$(tf_out nearline_age_days)"
COLDLINE="$(tf_out coldline_age_days)"
P_NAME="$(tf_out primary_bucket_name)"
S_NAME="$(tf_out secondary_bucket_name)"
check "outputs expose thresholds and bucket names" \
  test -n "$NEARLINE" -a -n "$COLDLINE" -a -n "$P_NAME" -a -n "$S_NAME"

echo
echo "Terraform: $PASS passed, $FAILED failed"
echo "Thresholds: NEARLINE at ${NEARLINE} days, COLDLINE at ${COLDLINE} days"

"$PY" "$SCRIPT_DIR/verify_lifecycle.py" "$PROJECT_ID" "$NEARLINE" "$COLDLINE" "$P_NAME" "$S_NAME"
PY_RC=$?

[[ $FAILED -eq 0 && $PY_RC -eq 0 ]]
