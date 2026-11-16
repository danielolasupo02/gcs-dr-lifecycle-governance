#!/usr/bin/env bash
# Phase 04: negative tests for encryption. T1 writes to the live primary bucket and deletes
# anything it manages to create; T2 to T4 run at plan time and change nothing.
# Usage: ./scripts/phase-04/failure_tests.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-04"
PASS=0; FAILED=0

[[ -z "$PROJECT_ID" ]] && { echo "usage: $0 <project-id>"; exit 1; }
BUCKET="gs://$(terraform -chdir="$TF_DIR" output -raw primary_bucket_name)"

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
  return $rc
}

plan() { terraform -chdir="$TF_DIR" plan -input=false -lock=false "$@"; }

echo "Phase 04 failure tests against $BUCKET"

echo
echo "T1: upload with a customer-supplied key (CSEK) is refused"
TMP="$(mktemp)"; echo "csek test $(date -u +%s)" > "$TMP"
CSEK="$(head -c 32 /dev/urandom | base64)"
if expect_rejected "cp with --encryption-key" "encrypt|restrict|enforce" \
     gcloud storage cp "$TMP" "$BUCKET/_probes/csek-test.txt" --encryption-key="$CSEK"; then
  echo "         upload unexpectedly succeeded, deleting it"
  gcloud storage rm "$BUCKET/_probes/csek-test.txt" >/dev/null 2>&1
fi
rm -f "$TMP"

echo
echo "T2: terraform destroy cannot delete the CMEK keys"
expect_rejected "plan -destroy" "prevent_destroy|cannot be destroyed" \
  plan -destroy

echo
echo "T3: rotation period outside 1 to 365 days is rejected"
expect_rejected "plan with kms_rotation_days=0" "kms_rotation_days must be between" \
  plan -var kms_rotation_days=0

echo
echo "T4: unsupported protection level is rejected"
expect_rejected "plan with kms_protection_level=EXTERNAL" "kms_protection_level must be" \
  plan -var kms_protection_level=EXTERNAL

echo
echo "Result: $PASS passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
