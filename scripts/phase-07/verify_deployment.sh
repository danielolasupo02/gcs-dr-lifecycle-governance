#!/usr/bin/env bash
# Phase 07: final verification. Terraform matches the deployment, the test document proves
# replication and versioning end to end, and the integrity audit is compliant.
# Writes validation/test-document.txt (two versions) to the primary bucket.
# Usage: ./scripts/phase-07/verify_deployment.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
export PROJECT_ID
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-07"
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

echo "Phase 07 final verification for project: $PROJECT_ID"
echo "Run at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo
echo "Terraform (final configuration)"
check "terraform fmt -check"                    terraform -chdir="$TF_DIR" fmt -check
check "terraform validate"                      terraform -chdir="$TF_DIR" validate
check "plan: no changes, deployment matches code" no_drift
COUNT="$(terraform -chdir="$TF_DIR" state list 2>/dev/null | wc -l | tr -d ' ')"
check "state tracks resources ($COUNT)"         test "${COUNT:-0}" -gt 0

P_NAME="$(tf_out primary_bucket_name)";   P_KEY="$(tf_out kms_key_primary)"
S_NAME="$(tf_out secondary_bucket_name)"; S_KEY="$(tf_out kms_key_secondary)"

echo
echo "Terraform: $PASS passed, $FAILED failed"

"$PY" "$SCRIPT_DIR/validate_deployment.py" "$PROJECT_ID" "$P_NAME" "$S_NAME" "$P_KEY" "$S_KEY"
VAL_RC=$?

echo
echo "Integrity audit"
"$REPO_ROOT/scripts/phase-06/run_audit.sh" --report "$REPO_ROOT/reports/audit-final.json" | tail -4
AUDIT_RC=${PIPESTATUS[0]}
check "audit is COMPLIANT (exit code 0)" test "$AUDIT_RC" -eq 0

echo
echo "Final: Terraform and audit $PASS passed, $FAILED failed; deployment validation exit $VAL_RC"
[[ $FAILED -eq 0 && $VAL_RC -eq 0 ]]
