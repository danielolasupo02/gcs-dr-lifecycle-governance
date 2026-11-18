#!/usr/bin/env bash
# Phase 08: verify access logging end to end.
#   Terraform -> audit config -> sink -> dataset -> generate known traffic -> find it in BigQuery
#   -> run the analysis queries as the read-only auditor.
# Writes one probe object (_probes/logging-probe-<timestamp>.txt) to the primary bucket.
# Logs take a few minutes to reach BigQuery, so this can take up to 15 minutes on first run.
# Usage: ./scripts/phase-08/verify_logging.sh [project-id]
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
export PROJECT_ID
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-08"
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

record() {  # record <rc> "<desc>" : count a step whose output was already shown
  if [[ $1 -eq 0 ]]; then PASS=$((PASS+1)); printf '=> PASS %s\n' "$2"
  else FAILED=$((FAILED+1)); printf '=> FAIL %s\n' "$2"; fi
}

no_drift() {
  terraform -chdir="$TF_DIR" plan -input=false -detailed-exitcode -lock=false >/dev/null 2>&1
}

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null; }

storage_audit_on() {
  gcloud projects get-iam-policy "$PROJECT_ID" --format=json | "$PY" -c '
import json, sys
cfg = [c for c in json.load(sys.stdin).get("auditConfigs", []) if c["service"] == "storage.googleapis.com"]
types = {t["logType"] for c in cfg for t in c.get("auditLogConfigs", [])}
sys.exit(0 if {"DATA_READ", "DATA_WRITE"} <= types else 1)'
}

echo "Phase 08 verification for project: $PROJECT_ID"
echo "Run at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo
echo "Terraform"
check "terraform fmt -check"               terraform -chdir="$TF_DIR" fmt -check
check "terraform validate"                 terraform -chdir="$TF_DIR" validate
check "plan shows no drift (exit code 0)"  no_drift
DATASET="$(tf_out access_logs_dataset)"; SINK="$(tf_out access_logs_sink)"
WRITER="$(tf_out access_logs_sink_writer)"; AUDITOR="$(tf_out auditor_service_account_email)"
P_NAME="$(tf_out primary_bucket_name)"
check "outputs expose dataset, sink, writer and auditor" test -n "$DATASET" -a -n "$SINK" -a -n "$WRITER" -a -n "$AUDITOR"

echo
echo "Logging configuration"
check "Data Access logs (DATA_READ, DATA_WRITE) on for Cloud Storage" storage_audit_on
check "sink $SINK routes to dataset $DATASET" \
  bash -c "gcloud logging sinks describe '$SINK' --project='$PROJECT_ID' --format='value(destination)' | grep -q 'datasets/$DATASET\$'"
"$PY" "$SCRIPT_DIR/access_logs.py" check --project "$PROJECT_ID" --dataset "$DATASET" --sink-writer "$WRITER"
record $? "dataset and sink writer access"

echo
echo "Generating known traffic"
PROBE="_probes/logging-probe-$(date -u +%Y%m%dT%H%M%SZ).txt"
TMP="$(mktemp)"; echo "logging probe $(date -u +%s)" > "$TMP"
gcloud storage cp "$TMP" "gs://$P_NAME/$PROBE" >/dev/null 2>&1 && echo "  write: gs://$P_NAME/$PROBE (as you)"
gcloud storage cat "gs://$P_NAME/$PROBE" >/dev/null 2>&1 && echo "  read:  same object (as you)"
gcloud storage cp "$TMP" "gs://$P_NAME/_probes/auditor-denied-$(date -u +%s).txt" \
  --impersonate-service-account="$AUDITOR" >/dev/null 2>&1 || echo "  write as auditor: denied (expected; should appear in the logs)"
rm -f "$TMP"
"$REPO_ROOT/scripts/phase-06/run_audit.sh" --report "$REPO_ROOT/reports/audit-logging.json" >/dev/null 2>&1
echo "  audit run as auditor (lists and reads both buckets)"

echo
"$PY" "$SCRIPT_DIR/access_logs.py" trace "$PROBE" --project "$PROJECT_ID" --dataset "$DATASET" --impersonate "$AUDITOR"
record $? "probe write traced into BigQuery (queried as auditor)"

echo
"$PY" "$SCRIPT_DIR/access_logs.py" report --project "$PROJECT_ID" --dataset "$DATASET" --impersonate "$AUDITOR"
record $? "analysis queries run as auditor"

echo
echo "Result: $PASS passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
