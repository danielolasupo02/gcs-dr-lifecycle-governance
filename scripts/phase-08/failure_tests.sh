#!/usr/bin/env bash
# Phase 08: negative tests for access logging.
#   T1  a refused write by the auditor is recorded in BigQuery as PERMISSION_DENIED
#   T2  the auditor cannot tamper with the log dataset
#   T3  an out-of-range retention period is rejected at plan time
# Usage: ./scripts/phase-08/failure_tests.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-08"
PY="$REPO_ROOT/.venv/bin/python"
PASS=0; FAILED=0

[[ -z "$PROJECT_ID" ]] && { echo "usage: $0 <project-id>"; exit 1; }
tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }
DATASET="$(tf_out access_logs_dataset)"; AUDITOR="$(tf_out auditor_service_account_email)"
P_NAME="$(tf_out primary_bucket_name)"

record() {
  if [[ $1 -eq 0 ]]; then PASS=$((PASS+1)); printf '=> %s: PASS\n' "$2"
  else FAILED=$((FAILED+1)); printf '=> %s: FAIL\n' "$2"; fi
}

echo "Phase 08 failure tests (dataset $DATASET)"

echo
echo "T1: a refused write is visible to security analysis"
TMP="$(mktemp)"; echo "denied write test" > "$TMP"
if gcloud storage cp "$TMP" "gs://$P_NAME/_probes/auditor-denied-$(date -u +%s).txt" \
     --impersonate-service-account="$AUDITOR" >/dev/null 2>&1; then
  echo "  write as auditor SUCCEEDED: the auditor is over-privileged"
else
  echo "  write as auditor refused, now looking for it in BigQuery"
fi
rm -f "$TMP"
"$PY" "$SCRIPT_DIR/access_logs.py" denied "$AUDITOR" --project "$PROJECT_ID" --dataset "$DATASET" --impersonate "$AUDITOR"
record $? "T1 denied request detected in BigQuery"

echo
echo "T2: the auditor cannot tamper with the logs"
"$PY" "$SCRIPT_DIR/access_logs.py" tamper --project "$PROJECT_ID" --dataset "$DATASET" --impersonate "$AUDITOR"
record $? "T2 log dataset is read-only to the auditor"

echo
echo "T3: retention outside 1 to 3650 days is rejected"
out="$(terraform -chdir="$TF_DIR" plan -input=false -lock=false -var access_log_retention_days=0 2>&1)"; rc=$?
echo "  $(grep -m1 "access_log_retention_days must be" <<<"$out" | sed 's/^[│ ]*//')"
[[ $rc -ne 0 ]] && grep -q "access_log_retention_days must be" <<<"$out"
record $? "T3 invalid retention rejected"

echo
echo "Result: $PASS passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
