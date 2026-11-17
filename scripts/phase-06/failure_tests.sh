#!/usr/bin/env bash
# Phase 06: negative tests for the audit and the auditor identity.
#   T1  audit policy flags every non-compliant case (unit tests, no cloud)
#   T2  audit against a missing bucket fails cleanly: exit 2, no traceback
#   T3  the auditor cannot write to the archive
#   T4  the auditor cannot use the CMEK key to encrypt or decrypt
# Usage: ./scripts/phase-06/failure_tests.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
export PROJECT_ID
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-06"
PY="$REPO_ROOT/.venv/bin/python"
PASS=0; FAILED=0

[[ -z "$PROJECT_ID" ]] && { echo "usage: $0 <project-id>"; exit 1; }
tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }
AUDITOR="$(tf_out auditor_service_account_email)"
P_NAME="$(tf_out primary_bucket_name)"
P_KEY="$(tf_out kms_key_primary)"

result() {  # result <ok:0|1> "<description>" "<detail>"
  if [[ $1 -eq 0 ]]; then PASS=$((PASS+1)); printf '  [PASS] %s\n' "$2"
  else FAILED=$((FAILED+1)); printf '  [FAIL] %s\n' "$2"; fi
  [[ -n "${3:-}" ]] && printf '         %s\n' "$(cut -c1-140 <<<"$3")"
}

echo "Phase 06 failure tests (auditor: $AUDITOR)"

echo
echo "T1: audit policy flags non-compliant objects"
out="$("$PY" -m unittest "$SCRIPT_DIR/test_audit_storage.py" -v 2>&1)"; rc=$?
grep -E "^test_" <<<"$out" | sed 's/^/    /'
result $rc "unit tests: $(grep -Eo 'Ran [0-9]+ tests' <<<"$out")" "$(tail -1 <<<"$out")"

echo
echo "T2: missing bucket gives a clean error, not a crash"
out="$("$PY" "$SCRIPT_DIR/audit_storage.py" --project "$PROJECT_ID" \
        --bucket "does-not-exist-$RANDOM$RANDOM=$P_KEY" --impersonate "$AUDITOR" \
        --report /tmp/audit-missing.json 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && ! grep -q "Traceback" <<<"$out"; ok=$?
result $ok "exit code 2 and no traceback (got $rc)" "$(grep -m1 ERROR <<<"$out")"

echo
echo "T3: the auditor cannot write to the archive"
TMP="$(mktemp)"; echo "auditor write test" > "$TMP"
out="$(gcloud storage cp "$TMP" "gs://$P_NAME/_probes/auditor-write-test.txt" \
        --impersonate-service-account="$AUDITOR" 2>&1)"; rc=$?
rm -f "$TMP"
if [[ $rc -eq 0 ]]; then
  gcloud storage rm "gs://$P_NAME/_probes/auditor-write-test.txt" >/dev/null 2>&1
  result 1 "upload as auditor is denied" "upload SUCCEEDED and was removed: auditor is over-privileged"
else
  grep -qiE "403|permission|denied|does not have" <<<"$out"; ok=$?
  result $ok "upload as auditor is denied" "$(grep -m1 -iE "403|permission|denied" <<<"$out")"
fi

echo
echo "T4: the auditor cannot use the CMEK key"
TMP="$(mktemp)"; echo "kms test" > "$TMP"
out="$(gcloud kms encrypt --key="$P_KEY" --plaintext-file="$TMP" --ciphertext-file=/tmp/kms-test.enc \
        --impersonate-service-account="$AUDITOR" 2>&1)"; rc=$?
rm -f "$TMP" /tmp/kms-test.enc
[[ $rc -ne 0 ]] && grep -qiE "403|permission|denied" <<<"$out"; ok=$?
result $ok "kms encrypt as auditor is denied" "$(grep -m1 -iE "403|permission|denied" <<<"$out")"

echo
echo "Result: $PASS passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
