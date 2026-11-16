#!/usr/bin/env bash
# Phase 02: verify Terraform code quality, zero drift, and live bucket configuration. Read-only.
# Usage: ./scripts/phase-02/verify_buckets.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-02"
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

no_drift() {  # plan -detailed-exitcode: 0 = no changes, 2 = changes pending, 1 = error
  terraform -chdir="$TF_DIR" plan -input=false -detailed-exitcode -lock=false >/dev/null 2>&1
}

echo "Phase 02 verification for project: $PROJECT_ID"
echo "Run at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo
echo "Terraform"
check "terraform fmt -check"               terraform -chdir="$TF_DIR" fmt -check
check "terraform validate"                 terraform -chdir="$TF_DIR" validate
check "plan shows no drift (exit code 0)"  no_drift

P_NAME="$(terraform -chdir="$TF_DIR" output -raw primary_bucket_name 2>/dev/null)"
P_REGION="$(terraform -chdir="$TF_DIR" output -raw primary_region 2>/dev/null)"
S_NAME="$(terraform -chdir="$TF_DIR" output -raw secondary_bucket_name 2>/dev/null)"
S_REGION="$(terraform -chdir="$TF_DIR" output -raw secondary_region 2>/dev/null)"
check "outputs expose both bucket names" test -n "$P_NAME" -a -n "$S_NAME"

echo
echo "Terraform: $PASS passed, $FAILED failed"

"$PY" "$SCRIPT_DIR/verify_buckets.py" "$PROJECT_ID" "$P_NAME" "$P_REGION" "$S_NAME" "$S_REGION"
PY_RC=$?

[[ $FAILED -eq 0 && $PY_RC -eq 0 ]]
