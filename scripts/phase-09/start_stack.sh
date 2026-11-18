#!/usr/bin/env bash
# Phase 09: start the cost alerting stack (exporter, Prometheus, Alertmanager, webhook receiver).
# Writes stack/.env from Terraform outputs, then docker compose up.
# Usage: ./scripts/phase-09/start_stack.sh [threshold-usd]   (default 10, matching the Phase 1 budget)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/phase-08"   # final configuration; phase 09 adds no infrastructure
STACK="$SCRIPT_DIR/stack"
ADC_FILE="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

command -v docker >/dev/null || { echo "docker not found"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker compose plugin not found"; exit 1; }
[[ -f "$ADC_FILE" ]] || { echo "No ADC file at $ADC_FILE. Run: gcloud auth application-default login"; exit 1; }

cat > "$STACK/.env" <<EOF
PROJECT_ID=$(tf_out project_id)
BUCKETS=$(tf_out primary_bucket_name),$(tf_out secondary_bucket_name)
IMPERSONATE_SA=$(tf_out auditor_service_account_email)
COST_THRESHOLD_USD=${1:-10}
COLLECT_INTERVAL_S=120
ADC_FILE=$ADC_FILE
HOST_UID=$(id -u)
HOST_GID=$(id -g)
EOF
mkdir -p "$STACK/data"
echo "Wrote $STACK/.env:"; grep -v ADC_FILE "$STACK/.env" | sed 's/^/  /'

cd "$STACK"
docker compose up -d --build
docker compose ps
echo
echo "Prometheus:   http://localhost:9090  (Cloud Shell: Web Preview > Change port > 9090)"
echo "Alertmanager: http://localhost:9093  (Web Preview > Change port > 9093)"
echo "Exporter:     curl -s localhost:9101/metrics | grep ^gcs_"
