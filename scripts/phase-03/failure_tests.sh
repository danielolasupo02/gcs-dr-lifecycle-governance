#!/usr/bin/env bash
# Phase 03: negative tests for lifecycle thresholds. All run at plan time; nothing is changed.
# Usage: ./scripts/phase-03/failure_tests.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-03"
PASS=0; FAILED=0

[[ -z "$PROJECT_ID" ]] && { echo "usage: $0 <project-id>"; exit 1; }

# expect_rejected "<description>" "<regex the error must match>" <command...>
expect_rejected() {
  local desc="$1" pattern="$2"; shift 2
  local out rc reason
  out="$("$@" 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]] && grep -qiE "$pattern" <<<"$out"; then
    printf '  [PASS] %s\n' "$desc"; PASS=$((PASS+1))
  else
    printf '  [FAIL] %s (rc=%s)\n' "$desc" "$rc"; FAILED=$((FAILED+1))
  fi
  reason="$(grep -iE "$pattern" <<<"$out" | head -1)"
  [[ -z "$reason" ]] && reason="$(grep -iE "error" <<<"$out" | head -1)"
  printf '         %s\n' "$(sed 's/^[│ ]*//' <<<"$reason" | cut -c1-140)"
}

plan() { terraform -chdir="$TF_DIR" plan -input=false -lock=false "$@"; }

echo "Phase 03 failure tests"

echo
echo "T1: COLDLINE before NEARLINE is rejected"
expect_rejected "plan with nearline=30, coldline=20" "must be greater than nearline_age_days" \
  plan -var nearline_age_days=30 -var coldline_age_days=20

echo
echo "T2: COLDLINE on the same day as NEARLINE is rejected"
expect_rejected "plan with nearline=30, coldline=30" "must be greater than nearline_age_days" \
  plan -var nearline_age_days=30 -var coldline_age_days=30

echo
echo "T3: a zero-day NEARLINE threshold is rejected"
expect_rejected "plan with nearline=0" "nearline_age_days must be at least 1" \
  plan -var nearline_age_days=0

echo
echo "Result: $PASS passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
