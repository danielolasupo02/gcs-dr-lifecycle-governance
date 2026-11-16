#!/usr/bin/env bash
# Phase 01: verify the Definition of Done. Read-only; safe to run repeatedly.
# Usage: ./scripts/phase-01/verify_env.sh <project-id>
set -uo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PY="$REPO_ROOT/.venv/bin/python"
PASS=0; FAILED=0

[[ -z "$PROJECT_ID" ]] && { echo "usage: $0 <project-id>"; exit 1; }

check() {  # check "<description>" <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [PASS] %s\n' "$desc"; PASS=$((PASS+1))
  else
    printf '  [FAIL] %s\n' "$desc"; FAILED=$((FAILED+1))
  fi
}

api_enabled() {
  [[ "$(gcloud services list --enabled --project="$PROJECT_ID" \
        --filter="config.name=$1" --format='value(config.name)')" == "$1" ]]
}

echo "Phase 01 verification for project: $PROJECT_ID"
echo "Run at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo
echo "gcloud configuration"
ACTIVE="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)"
CFG_PROJECT="$(gcloud config get-value project 2>/dev/null)"
echo "  active account : ${ACTIVE:-<none>}"
echo "  config project : ${CFG_PROJECT:-<none>}"
check "Active gcloud account is set"              test -n "$ACTIVE"
check "gcloud core/project matches $PROJECT_ID"    test "$CFG_PROJECT" = "$PROJECT_ID"

echo
echo "Application Default Credentials"
ADC_FILE="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
QUOTA="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('quota_project_id',''))" "$ADC_FILE" 2>/dev/null)"
echo "  quota project  : ${QUOTA:-<none>}"
check "ADC can mint an access token"               gcloud auth application-default print-access-token
check "ADC quota project matches $PROJECT_ID"      test "$QUOTA" = "$PROJECT_ID"

echo
echo "APIs"
while read -r api; do
  check "$api enabled" api_enabled "$api"
done < <(grep -vE '^\s*(#|$)' "$SCRIPT_DIR/apis.txt")

echo
echo "Storage API reachable"
check "gcloud storage buckets list succeeds"       gcloud storage buckets list --project="$PROJECT_ID"
check "Python client authenticates via ADC"        "$PY" "$SCRIPT_DIR/verify_python_auth.py" "$PROJECT_ID"

echo
echo "Terraform"
check "terraform >= 1.5 installed" bash -c \
  'v=$(terraform version -json | python3 -c "import json,sys;print(json.load(sys.stdin)[\"terraform_version\"])"); \
   python3 -c "import sys;a=tuple(map(int,sys.argv[1].split(\".\")[:2]));sys.exit(0 if a>=(1,5) else 1)" "$v"'
check "terraform/phase-01 validates" bash -c \
  "cd '$REPO_ROOT/terraform/phase-01' && terraform init -backend=false -input=false >/dev/null && terraform validate"

echo
echo "Result: $PASS passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
