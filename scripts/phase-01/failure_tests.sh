#!/usr/bin/env bash
# Phase 01: negative tests. Each test expects a FAILURE and passes when the system rejects the bad input.
# Nothing here changes cloud state.
# Usage: ./scripts/phase-01/failure_tests.sh <project-id>
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PY="$REPO_ROOT/.venv/bin/python"
BOGUS="nonexistent-proj-$RANDOM$RANDOM"
PASS=0; FAILED=0

[[ -z "$PROJECT_ID" ]] && { echo "usage: $0 <project-id>"; exit 1; }

expect_fail() {  # expect_fail "<description>" <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [FAIL] %s (command unexpectedly succeeded)\n' "$desc"; FAILED=$((FAILED+1))
  else
    printf '  [PASS] %s (rejected as expected)\n' "$desc"; PASS=$((PASS+1))
  fi
}

echo "Phase 01 failure tests"

echo
echo "T1: gcloud against a project that does not exist"
expect_fail "gcloud storage buckets list --project=$BOGUS" \
  gcloud storage buckets list --project="$BOGUS"

echo
echo "T2: Python client against a project that does not exist"
expect_fail "verify_python_auth.py $BOGUS returns non-zero" \
  "$PY" "$SCRIPT_DIR/verify_python_auth.py" "$BOGUS"

echo
echo "T3: Unauthenticated call to the Storage JSON API"
code="$(curl -s -o /dev/null -w '%{http_code}' \
  "https://storage.googleapis.com/storage/v1/b?project=$PROJECT_ID")"
echo "  HTTP status: $code"
expect_fail "anonymous bucket listing is denied (expect 401)" test "$code" = "200"

echo
echo "T4: Terraform variable validation rejects a malformed project ID"
expect_fail "terraform plan -var project_id=BAD_ID" bash -c \
  "cd '$REPO_ROOT/terraform/phase-01' && terraform init -backend=false -input=false >/dev/null && \
   terraform plan -input=false -var 'project_id=BAD_ID'"

echo
echo "Result: $PASS passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
