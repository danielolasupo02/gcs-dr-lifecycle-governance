#!/usr/bin/env bash
# Phase 06: verify Terraform, the auditor identity, and a full audit run that produces a report.
# Usage: ./scripts/phase-06/verify_audit.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
export PROJECT_ID
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-06"
PY="$REPO_ROOT/.venv/bin/python"
REPORT="$REPO_ROOT/reports/audit-verify.json"
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

report_ok() {  # report has both buckets, at least one object, and no FAIL
  "$PY" - "$REPORT" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
ok = len(r["buckets"]) == 2 and r["totals"]["objects"] > 0 and r["totals"].get("FAIL", 0) == 0
sys.exit(0 if ok else 1)
EOF
}

echo "Phase 06 verification for project: $PROJECT_ID"
echo "Run at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo
echo "Terraform"
check "terraform fmt -check"               terraform -chdir="$TF_DIR" fmt -check
check "terraform validate"                 terraform -chdir="$TF_DIR" validate
check "plan shows no drift (exit code 0)"  no_drift
AUDITOR="$(terraform -chdir="$TF_DIR" output -raw auditor_service_account_email 2>/dev/null)"
check "output exposes auditor service account" test -n "$AUDITOR"

echo
echo "Auditor identity: $AUDITOR"
check "service account exists"             gcloud iam service-accounts describe "$AUDITOR" --project="$PROJECT_ID"
check "I can impersonate the auditor"      gcloud auth print-access-token --impersonate-service-account="$AUDITOR"

echo
echo "Audit run"
"$SCRIPT_DIR/run_audit.sh" --report "$REPORT"
RC=$?
check "audit exit code is 0 (compliant)"   test "$RC" -eq 0
check "report covers both buckets, no FAIL" report_ok

echo
echo "Result: $PASS passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
