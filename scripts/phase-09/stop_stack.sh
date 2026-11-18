#!/usr/bin/env bash
# Phase 09: stop the cost alerting stack. Keeps stack/data/alerts.jsonl.
# Usage: ./scripts/phase-09/stop_stack.sh
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stack"
docker compose down
