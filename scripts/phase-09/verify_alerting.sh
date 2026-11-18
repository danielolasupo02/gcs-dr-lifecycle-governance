#!/usr/bin/env bash
# Phase 09: verify the cost alerting stack is running, scraping, evaluating rules, and that the
# exporter's byte count matches what Cloud Storage reports. Read-only.
# Usage: ./scripts/phase-09/verify_alerting.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$SCRIPT_DIR/stack"
PASS=0; FAILED=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [PASS] %s\n' "$desc"; PASS=$((PASS+1))
  else
    printf '  [FAIL] %s\n' "$desc"; FAILED=$((FAILED+1))
  fi
}

metric() { curl -s localhost:9101/metrics | awk -v m="$1" '$1==m {print $2}'; }

running() { [[ "$(cd "$STACK" && docker compose ps --status running --services | grep -cx "$1")" == "1" ]]; }

target_up() {
  curl -s localhost:9090/api/v1/targets | python3 -c '
import json, sys
t = [x for x in json.load(sys.stdin)["data"]["activeTargets"] if x["labels"]["job"] == "gcs-cost-exporter"]
sys.exit(0 if t and t[0]["health"] == "up" else 1)'
}

rules_loaded() {
  curl -s localhost:9090/api/v1/rules | python3 -c '
import json, sys
names = {r["name"] for g in json.load(sys.stdin)["data"]["groups"] for r in g["rules"]}
sys.exit(0 if {"GCSStorageCostAboveThreshold", "GCSCostExporterDown", "GCSCostDataStale"} <= names else 1)'
}

not_firing() {
  curl -s localhost:9090/api/v1/alerts | python3 -c '
import json, sys
firing = [a for a in json.load(sys.stdin)["data"]["alerts"] if a["state"] == "firing"]
sys.exit(0 if not firing else 1)'
}

bytes_match() {  # exporter total (all versions) vs gcloud storage du -a
  local exp gc b
  exp="$(curl -s localhost:9101/metrics | awk '$1 ~ /^gcs_bucket_bytes\{/ {s+=$2} END {printf "%.0f", s}')"
  gc=0
  for b in $(grep ^BUCKETS "$STACK/.env" | cut -d= -f2 | tr , ' '); do
    gc=$(( gc + $(gcloud storage du -s -a "gs://$b" | awk '{print $1}') ))
  done
  echo "    exporter: $exp bytes, gcloud storage du -a: $gc bytes" >&2
  [[ "$exp" == "$gc" ]]
}

echo "Phase 09 verification"
echo "Run at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo
echo "Stack"
for svc in exporter prometheus alertmanager receiver; do
  check "$svc container running" running "$svc"
done
check "Alertmanager ready" curl -sf localhost:9093/-/ready

echo
echo "Exporter"
TOTAL="$(metric gcs_estimated_monthly_storage_cost_usd_total)"
THRESH="$(metric gcs_cost_threshold_usd)"
echo "  estimated monthly storage cost: \$${TOTAL:-?}   threshold: \$${THRESH:-?}"
check "cost metric exposed"                test -n "$TOTAL"
check "last collection succeeded"          test -n "$(metric gcs_cost_exporter_last_success_timestamp_seconds)"
check "byte count matches Cloud Storage"   bytes_match
bytes_match 2>&1 >/dev/null | head -1

echo
echo "Prometheus"
check "scrape target gcs-cost-exporter is up" target_up
check "3 alert rules loaded"                 rules_loaded
check "no alert firing at the real threshold" not_firing

echo
echo "Result: $PASS passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
