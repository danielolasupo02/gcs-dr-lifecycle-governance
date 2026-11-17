#!/usr/bin/env bash
# Phase 05: verify Terraform, the replication job, Pub/Sub IAM, then a live replication test.
# Uploads one probe object to primary (_probes/replication-<timestamp>.txt). Can take a few
# minutes while it waits for the object to appear in secondary.
# Usage: ./scripts/phase-05/verify_replication.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-05"
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

job_field() { gcloud transfer jobs describe "$JOB" --project="$PROJECT_ID" --format="value($1)" 2>/dev/null; }

has_project_role() {  # has_project_role <member> <role>
  gcloud projects get-iam-policy "$PROJECT_ID" --flatten="bindings[].members" \
    --filter="bindings.members:$1 AND bindings.role:$2" --format="value(bindings.role)" | grep -qx "$2"
}

echo "Phase 05 verification for project: $PROJECT_ID"
echo "Run at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo
echo "Terraform"
check "terraform fmt -check"               terraform -chdir="$TF_DIR" fmt -check
check "terraform validate"                 terraform -chdir="$TF_DIR" validate
check "plan shows no drift (exit code 0)"  no_drift

JOB="$(tf_out replication_job_name)"
P_NAME="$(tf_out primary_bucket_name)";  S_NAME="$(tf_out secondary_bucket_name)"
STS="$(tf_out sts_service_agent_email)"; GCS="$(tf_out gcs_service_agent_email)"
S_KEY="$(tf_out kms_key_secondary)"
check "outputs expose job, buckets, agents and key" \
  test -n "$JOB" -a -n "$P_NAME" -a -n "$S_NAME" -a -n "$STS" -a -n "$GCS" -a -n "$S_KEY"

echo
echo "Replication job: $JOB"
check "job status is ENABLED"                  test "$(job_field status)" = "ENABLED"
check "job source is $P_NAME"                  test "$(job_field replicationSpec.gcsDataSource.bucketName)" = "$P_NAME"
check "job sink is $S_NAME"                    test "$(job_field replicationSpec.gcsDataSink.bucketName)" = "$S_NAME"

echo
echo "Pub/Sub IAM (project level)"
check "transfer agent has pubsub.editor"       has_project_role "serviceAccount:$STS" roles/pubsub.editor
check "storage agent has pubsub.publisher"     has_project_role "serviceAccount:$GCS" roles/pubsub.publisher

echo
echo "Terraform and job: $PASS passed, $FAILED failed"

"$PY" "$SCRIPT_DIR/replication_check.py" verify "$PROJECT_ID" "$P_NAME" "$S_NAME" "$STS" "$S_KEY"
PY_RC=$?

[[ $FAILED -eq 0 && $PY_RC -eq 0 ]]
