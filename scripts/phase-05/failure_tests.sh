#!/usr/bin/env bash
# Phase 05: DR failure scenarios against the live buckets. Test objects go under _probes/.
#   T1  accidental delete in primary must not remove the DR copy
#   T2  a corrupting overwrite replicates, but the good version stays recoverable in secondary
#   T3  plan rejects an invalid overwrite_when value
# T1 and T2 each wait for real replication, so the whole run takes several minutes.
# Usage: ./scripts/phase-05/failure_tests.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-05"
PY="$REPO_ROOT/.venv/bin/python"
PASS=0; FAILED=0

[[ -z "$PROJECT_ID" ]] && { echo "usage: $0 <project-id>"; exit 1; }

P_NAME="$(terraform -chdir="$TF_DIR" output -raw primary_bucket_name)"
S_NAME="$(terraform -chdir="$TF_DIR" output -raw secondary_bucket_name)"

scenario() {  # scenario "<label>" <python subcommand>
  if "$PY" "$SCRIPT_DIR/replication_check.py" "$2" "$PROJECT_ID" "$P_NAME" "$S_NAME"; then
    PASS=$((PASS+1)); printf '=> %s: PASS\n' "$1"
  else
    FAILED=$((FAILED+1)); printf '=> %s: FAIL\n' "$1"
  fi
}

echo "Phase 05 failure tests: gs://$P_NAME -> gs://$S_NAME"

scenario "T1 delete does not propagate" delete
scenario "T2 bad overwrite is recoverable" overwrite

echo
echo "T3: invalid overwrite_when is rejected at plan time"
out="$(terraform -chdir="$TF_DIR" plan -input=false -lock=false -var replication_overwrite_when=SOMETIMES 2>&1)"
if [[ $? -ne 0 ]] && grep -q "replication_overwrite_when must be" <<<"$out"; then
  PASS=$((PASS+1)); echo "  [PASS] plan with replication_overwrite_when=SOMETIMES"
else
  FAILED=$((FAILED+1)); echo "  [FAIL] plan with replication_overwrite_when=SOMETIMES"
fi
echo "         $(grep -m1 "replication_overwrite_when must be" <<<"$out" | sed 's/^[│ ]*//')"

echo
echo "Result: $PASS passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
