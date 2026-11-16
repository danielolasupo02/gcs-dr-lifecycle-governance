#!/usr/bin/env bash
# Phase 01: authenticate gcloud + ADC, set project config, enable APIs, prepare Python venv.
# Usage: ./scripts/phase-01/setup_env.sh <project-id>
# Headless machine (no browser): HEADLESS=1 ./scripts/phase-01/setup_env.sh <project-id>
set -euo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-}}"
REGION="${REGION:-us-central1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BROWSER_FLAG=""
[[ "${HEADLESS:-0}" == "1" ]] && BROWSER_FLAG="--no-launch-browser"

log()  { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

[[ -z "$PROJECT_ID" ]] && fail "usage: $0 <project-id>"

log "1/7 Checking local tooling"
for bin in gcloud terraform python3; do
  command -v "$bin" >/dev/null || fail "$bin not found on PATH"
done
gcloud --version | head -1
terraform version | head -1
python3 --version

log "2/7 gcloud user login"
ACTIVE="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
if [[ -z "$ACTIVE" ]]; then
  gcloud auth login $BROWSER_FLAG
  ACTIVE="$(gcloud auth list --filter=status:ACTIVE --format='value(account)')"
fi
echo "Active account: $ACTIVE"

log "3/7 Setting gcloud config (project + default region)"
gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null \
  || fail "Project $PROJECT_ID not found or $ACTIVE has no access"
gcloud config set project "$PROJECT_ID"
gcloud config set compute/region "$REGION"

log "4/7 Application Default Credentials (used by Terraform and Python)"
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  gcloud auth application-default login $BROWSER_FLAG
fi
# Without a quota project, client libraries bill API quota to a Google-owned project and some calls 403.
gcloud auth application-default set-quota-project "$PROJECT_ID"

log "5/7 Checking billing is linked"
BILLING="$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || echo unknown)"
echo "billingEnabled=$BILLING"
[[ "$BILLING" == "False" ]] && fail "Billing is not enabled on $PROJECT_ID. Link a billing account first."

log "6/7 Enabling required APIs"
mapfile -t APIS < <(grep -vE '^\s*(#|$)' "$SCRIPT_DIR/apis.txt")
gcloud services enable "${APIS[@]}" --project="$PROJECT_ID"

log "7/7 Python virtual environment"
python3 -m venv "$REPO_ROOT/.venv"
"$REPO_ROOT/.venv/bin/pip" install --quiet --upgrade pip
"$REPO_ROOT/.venv/bin/pip" install --quiet -r "$REPO_ROOT/requirements.txt"
"$REPO_ROOT/.venv/bin/python" -c "from google.cloud import storage; print('google-cloud-storage', storage.__version__)"

log "Setup complete. Next: ./scripts/phase-01/verify_env.sh $PROJECT_ID"
