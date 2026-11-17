#!/usr/bin/env bash
# Phase 07: recovery drills against the live deployment. Run verify_deployment.sh first.
#   T1  configuration drift: a manual label change is detected by plan and reverted by apply
#   T2  lost primary copy: restore validation/test-document.txt from the secondary region
#   T3  bad revision: roll the primary back to version 1 from its version history
#   T4  the archive is still compliant after all three
# T1 runs terraform apply -auto-approve to put the label back. Nothing else is changed.
# Usage: ./scripts/phase-07/dr_drills.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
export PROJECT_ID
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-07"
PY="$REPO_ROOT/.venv/bin/python"
PASS=0; FAILED=0

[[ -z "$PROJECT_ID" ]] && { echo "usage: $0 <project-id>"; exit 1; }
tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }
P_NAME="$(tf_out primary_bucket_name)"; P_KEY="$(tf_out kms_key_primary)"
S_NAME="$(tf_out secondary_bucket_name)"

result() {  # result <rc> "<label>"
  if [[ $1 -eq 0 ]]; then PASS=$((PASS+1)); printf '=> %s: PASS\n' "$2"
  else FAILED=$((FAILED+1)); printf '=> %s: FAIL\n' "$2"; fi
}

plan_rc() { terraform -chdir="$TF_DIR" plan -input=false -detailed-exitcode -lock=false >/dev/null 2>&1; echo $?; }

echo "Phase 07 DR drills: gs://$P_NAME -> gs://$S_NAME"

echo
echo "T1: drift is detected and reverted"
gcloud storage buckets update "gs://$P_NAME" --update-labels=environment=prod-manual-edit >/dev/null 2>&1
echo "  changed label environment=prod-manual-edit outside Terraform"
rc1="$(plan_rc)"; echo "  plan exit code after manual change: $rc1 (2 = changes needed)"
terraform -chdir="$TF_DIR" apply -input=false -auto-approve >/dev/null 2>&1
rc2="$(plan_rc)"; echo "  plan exit code after apply: $rc2 (0 = matches code)"
LABEL="$(gcloud storage buckets describe "gs://$P_NAME" --format='value(labels.environment)' 2>/dev/null)"
echo "  label is now: environment=$LABEL"
[[ "$rc1" == "2" && "$rc2" == "0" && "$LABEL" == "lab" ]]; result $? "T1 drift detected and reverted"

echo
"$PY" "$SCRIPT_DIR/dr_drills.py" restore "$PROJECT_ID" "$P_NAME" "$S_NAME" "$P_KEY"
result $? "T2 restore from secondary region"

echo
"$PY" "$SCRIPT_DIR/dr_drills.py" rollback "$PROJECT_ID" "$P_NAME" "$S_NAME" "$P_KEY"
result $? "T3 roll back to version 1"

echo
echo "T4: archive still compliant after the drills"
"$REPO_ROOT/scripts/phase-06/run_audit.sh" --report "$REPO_ROOT/reports/audit-after-drills.json" | tail -4
result "${PIPESTATUS[0]}" "T4 audit compliant after drills"

echo
echo "Result: $PASS passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
