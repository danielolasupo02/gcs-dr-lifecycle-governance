#!/usr/bin/env bash
# Phase 01: billing budget scoped to this project with alerts at 50%, 90% and 100%.
# Usage: ./scripts/phase-01/create-budget.sh [project-id] [amount-usd]
set -euo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
AMOUNT="${2:-10}"
NAME="gcs-dr-lifecycle-${PROJECT_ID}"

[[ -z "$PROJECT_ID" ]] && { echo "usage: $0 <project-id> [amount-usd]"; exit 1; }

BILLING_ACCOUNT="$(gcloud billing projects describe "$PROJECT_ID" \
  --format='value(billingAccountName)' | sed 's#billingAccounts/##')"
[[ -z "$BILLING_ACCOUNT" ]] && { echo "No billing account linked to $PROJECT_ID"; exit 1; }

# The Budgets API is called through the ADC quota project, so it must be on there.
gcloud services enable billingbudgets.googleapis.com --project="$PROJECT_ID"

if gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
     --format='value(displayName)' | grep -qx "$NAME"; then
  echo "Budget $NAME already exists, nothing to do"
  exit 0
fi

gcloud billing budgets create \
  --billing-account="$BILLING_ACCOUNT" \
  --display-name="$NAME" \
  --budget-amount="${AMOUNT}USD" \
  --filter-projects="projects/${PROJECT_ID}" \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0

echo "Created budget $NAME (${AMOUNT} USD) on billing account $BILLING_ACCOUNT"
