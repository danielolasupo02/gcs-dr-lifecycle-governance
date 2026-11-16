#!/usr/bin/env bash
# Phase 04: verify Terraform state, then CMEK keys, IAM, bucket encryption and a real probe write.
# Writes one small probe object per bucket (_probes/cmek-probe.txt); everything else is read-only.
# Usage: ./scripts/phase-04/verify_cmek.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-04"
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

echo "Phase 04 verification for project: $PROJECT_ID"
echo "Run at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo
echo "Terraform"
check "terraform fmt -check"               terraform -chdir="$TF_DIR" fmt -check
check "terraform validate"                 terraform -chdir="$TF_DIR" validate
check "plan shows no drift (exit code 0)"  no_drift

AGENT="$(tf_out gcs_service_agent_email)"
P_NAME="$(tf_out primary_bucket_name)";   P_KEY="$(tf_out kms_key_primary)"
S_NAME="$(tf_out secondary_bucket_name)"; S_KEY="$(tf_out kms_key_secondary)"
check "outputs expose keys, buckets and service agent" \
  test -n "$AGENT" -a -n "$P_NAME" -a -n "$P_KEY" -a -n "$S_NAME" -a -n "$S_KEY"

echo
echo "Terraform: $PASS passed, $FAILED failed"

"$PY" "$SCRIPT_DIR/verify_cmek.py" "$PROJECT_ID" "$AGENT" "$P_NAME" "$P_KEY" "$S_NAME" "$S_KEY"
PY_RC=$?

[[ $FAILED -eq 0 && $PY_RC -eq 0 ]]
