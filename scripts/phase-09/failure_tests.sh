#!/usr/bin/env bash
# Phase 09: prove the alerts fire, reach Alertmanager, get delivered, and resolve.
#   T1  promtool unit tests for the alert rules (no cloud, no stack)
#   T2  cost above threshold: threshold dropped to $0.000000001, alert fires and is delivered,
#       threshold restored, alert resolves
#   T3  exporter down: exporter stopped, GCSCostExporterDown fires and is delivered, exporter
#       restarted, alert resolves
# Takes about 6 to 8 minutes. Set HOLD=1 to pause while T2 is firing, for screenshots.
# Usage: [HOLD=1] ./scripts/phase-09/failure_tests.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$SCRIPT_DIR/stack"
LOG="$STACK/data/alerts.jsonl"
PROM_IMAGE="prom/prometheus:v2.55.1"
TIMEOUT_S=360
PASS=0; FAILED=0
REAL_THRESHOLD="$(grep ^COST_THRESHOLD_USD "$STACK/.env" | cut -d= -f2)"

record() {
  if [[ $1 -eq 0 ]]; then PASS=$((PASS+1)); printf '=> %s: PASS\n' "$2"
  else FAILED=$((FAILED+1)); printf '=> %s: FAIL\n' "$2"; fi
}

compose() { (cd "$STACK" && docker compose "$@"); }

# wait_delivered <alertname> <firing|resolved> <log line offset>
wait_delivered() {
  local start=$SECONDS
  while (( SECONDS - start < TIMEOUT_S )); do
    if tail -n +"$(( $3 + 1 ))" "$LOG" 2>/dev/null | grep -q "\"status\": \"$2\", \"alertname\": \"$1\""; then
      echo "  $1 $2 delivered after $(( SECONDS - start ))s:"
      tail -n +"$(( $3 + 1 ))" "$LOG" | grep "\"alertname\": \"$1\"" | grep "\"$2\"" | tail -1 | sed 's/^/    /'
      return 0
    fi
    sleep 10
  done
  echo "  timed out after ${TIMEOUT_S}s waiting for $1 $2"
  return 1
}

lines() { wc -l < "$LOG" 2>/dev/null || echo 0; }

echo "Phase 09 failure tests"
touch "$LOG"

echo
echo "T1: promtool unit tests for the alert rules"
docker run --rm -v "$STACK/prometheus:/rules:ro" -w /rules --entrypoint promtool "$PROM_IMAGE" \
  test rules alert_rules_test.yml
record $? "T1 rule unit tests"

echo
echo "T2: storage cost above threshold"
OFFSET="$(lines)"
COST_THRESHOLD_USD=0.000000001 compose up -d exporter >/dev/null 2>&1
echo "  threshold lowered to \$0.000000001 (real estimate is above that)"
wait_delivered GCSStorageCostAboveThreshold firing "$OFFSET"; rc_fire=$?
if [[ "${HOLD:-0}" == "1" ]]; then
  read -r -p "  HOLD: alert is firing. Take screenshots in Prometheus and Alertmanager, then press Enter " _
fi
COST_THRESHOLD_USD="$REAL_THRESHOLD" compose up -d exporter >/dev/null 2>&1
echo "  threshold restored to \$$REAL_THRESHOLD"
wait_delivered GCSStorageCostAboveThreshold resolved "$OFFSET"; rc_res=$?
[[ $rc_fire -eq 0 && $rc_res -eq 0 ]]; record $? "T2 cost alert fired, delivered and resolved"

echo
echo "T3: exporter down"
OFFSET="$(lines)"
compose stop exporter >/dev/null 2>&1
echo "  exporter stopped"
wait_delivered GCSCostExporterDown firing "$OFFSET"; rc_fire=$?
compose start exporter >/dev/null 2>&1
echo "  exporter started"
wait_delivered GCSCostExporterDown resolved "$OFFSET"; rc_res=$?
[[ $rc_fire -eq 0 && $rc_res -eq 0 ]]; record $? "T3 exporter-down alert fired, delivered and resolved"

echo
echo "Result: $PASS passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
