#!/usr/bin/env bash
# Phase 02: negative tests. Each one tries something the configuration must reject.
# T2 and T3 touch the live bucket; if either unexpectedly succeeds, the change is reverted at once.
# Usage: ./scripts/phase-02/failure_tests.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-02"
PASS=0; FAILED=0

[[ -z "$PROJECT_ID" ]] && { echo "usage: $0 <project-id>"; exit 1; }
BUCKET="gs://$(terraform -chdir="$TF_DIR" output -raw primary_bucket_name)"

# expect_rejected "<description>" "<regex the error must match>" <command...>
# Passes only if the command fails AND the error mentions the expected reason,
# so a typo or unrelated error cannot count as a pass.
expect_rejected() {
  local desc="$1" pattern="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]] && grep -qiE "$pattern" <<<"$out"; then
    printf '  [PASS] %s\n' "$desc"; PASS=$((PASS+1))
  else
    printf '  [FAIL] %s (rc=%s)\n' "$desc" "$rc"; FAILED=$((FAILED+1))
  fi
  local reason
  reason="$(grep -iE "$pattern" <<<"$out" | head -1)"
  [[ -z "$reason" ]] && reason="$(grep -iE "error" <<<"$out" | head -1)"
  printf '         %s\n' "$(sed 's/^[│ ]*//' <<<"$reason" | cut -c1-140)"
  return $rc
}

echo "Phase 02 failure tests against $BUCKET"

echo
echo "T1: secondary region equal to primary is rejected at plan time"
expect_rejected "plan with region_secondary=us-central1" "must differ from region_primary" \
  terraform -chdir="$TF_DIR" plan -input=false -lock=false -var region_secondary=us-central1

echo
echo "T2: granting public read is blocked by public access prevention"
if ! expect_rejected "add allUsers as objectViewer" "public access prevention|412" \
     gcloud storage buckets add-iam-policy-binding "$BUCKET" \
       --member=allUsers --role=roles/storage.objectViewer; then :; else
  echo "         reverting unexpected public binding"
  gcloud storage buckets remove-iam-policy-binding "$BUCKET" \
    --member=allUsers --role=roles/storage.objectViewer >/dev/null 2>&1
fi

echo
echo "T3: legacy ACLs are refused under uniform bucket-level access"
# Uses a non-public entity (the caller's own account) so public access prevention cannot
# be the control that rejects it. Only uniform bucket-level access can.
ME="$(gcloud auth list --filter=status:ACTIVE --format='value(account)')"
if ! expect_rejected "add bucket ACL grant for user-$ME" "uniform bucket-level access|uniform_bucket_level_access|uniform" \
     gcloud storage buckets update "$BUCKET" --add-acl-grant="entity=user-$ME,role=READER"; then :; else
  echo "         reverting unexpected ACL grant"
  gcloud storage buckets update "$BUCKET" --remove-acl-grant="user-$ME" >/dev/null 2>&1
fi

echo
echo "T4: malformed region is rejected by variable validation"
expect_rejected "plan with region_primary=US-CENTRAL1" "lowercase GCP region" \
  terraform -chdir="$TF_DIR" plan -input=false -lock=false -var region_primary=US-CENTRAL1

echo
echo "Result: $PASS passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
